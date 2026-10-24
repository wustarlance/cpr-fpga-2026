`timescale 1ns/1ps
//=============================================================================
// audio_tmg_top.v —— 音频链综合 / 时序分析专用顶层（不属于上板设计）
//-----------------------------------------------------------------------------
// 目的：把 rtl/audio 下的 WAV 播放链 + 波形绘制器单独拎出来，在 TD 里跑
//       综合 → 布局 → 布线 → 时序，得到
//         * 资源占用（LUT / REG / BRAM / DSP）
//         * 三个时钟域各自的 SWNS / HWNS
//         * 最差路径，判断瓶颈在 sd_clk(100M) 还是 mclk/vid_clk
//
// 为什么单独建顶层，而不是直接综合 top：
//   1. 现有 top 的 SD 控制器被 BMP 通路独占，音频链还没有接进去，
//      直接综合 top 这套代码根本不会被例化、会被优化掉；
//   2. 单独顶层可以把时钟直接从端口给（100 / 12.288 / 25.175 MHz），
//      不经过 PLL，约束干净，也便于和历史网表对比（旧工程 wav_tmg_board
//      就是这么跑的，结果可直接对照）。
//
// 三个时钟域（彼此异步，SDC 里用 set_clock_groups 声明）：
//   I_sd_clk     100.000 MHz  SD 扇区读 + wav_reader 头解析（最紧的域）
//   I_mclk        12.288 MHz  pcm_frame_tick + pcm_player（48 kHz 帧节拍）
//   I_video_clk   25.175 MHz  PCM 域输出 + ACR + 波形绘制（640×480 扫描）
//
// 视频侧为什么要自己造扫描计数器：
//   wave_painter 的接口是"每个像素问一次"，它不产生时序。上板时这些坐标
//   来自 HDMI 核/视频时序模块；独立顶层里给一个等效的 640×480@60Hz 计数器
//   即可（25.175 MHz / 800×525 = 59.94 Hz），时序特性和真机一致。
//=============================================================================
module audio_tmg_top #(
    parameter [31:0]  START_SECTOR = 32'd12000,
    parameter integer MCLK_HZ      = 12_288_000
)(
    /* ---- 三个时钟（独立顶层直接从端口给，不经 PLL） ---- */
    input  wire        I_sd_clk,        // 100.000 MHz
    input  wire        I_mclk,          //  12.288 MHz
    input  wire        I_video_clk,     //  25.175 MHz（像素时钟）
    input  wire        I_rst_n,         // 低有效，三个域各自同步释放

    /* ---- SD 卡 SPI（真实引脚方向） ---- */
    input  wire        I_sd_miso,
    output wire        O_sd_ncs,
    output wire        O_sd_dclk,
    output wire        O_sd_mosi,

    /* ---- 控制（准静态，按键） ---- */
    input  wire [3:0]  I_ctrl,          // {loop, mute, stop, play}

    /* ---- 送 HDMI 核的音频口（片内用；这里引出来看 IO 时序） ---- */
    output wire        O_audio_valid,
    output wire [23:0] O_audio_l,
    output wire [23:0] O_audio_r,
    output wire        O_acr_valid,
    output wire [19:0] O_acr_cts,
    output wire [19:0] O_acr_n,

    /* ---- 波形绘制结果 ---- */
    output wire        O_pix_hit,
    output wire [23:0] O_pix_rgb,
    output wire        O_pix_de_d,

    /* ---- 状态归约（32 位状态口不能直接引 pad，XOR 成 8 位） ---- */
    output wire [7:0]  O_dbg
);

//--------------------------------------------------------------------------
// 复位：三个域各自"异步置位、同步释放"
//--------------------------------------------------------------------------
reg [2:0] S_rst_sd, S_rst_mclk, S_rst_vid;

always @(posedge I_sd_clk or negedge I_rst_n) begin
    if (!I_rst_n) S_rst_sd <= 3'b000;
    else          S_rst_sd <= {S_rst_sd[1:0], 1'b1};
end

always @(posedge I_mclk or negedge I_rst_n) begin
    if (!I_rst_n) S_rst_mclk <= 3'b000;
    else          S_rst_mclk <= {S_rst_mclk[1:0], 1'b1};
end

always @(posedge I_video_clk or negedge I_rst_n) begin
    if (!I_rst_n) S_rst_vid <= 3'b000;
    else          S_rst_vid <= {S_rst_vid[1:0], 1'b1};
end

wire W_rst_sd   = ~S_rst_sd[2];
wire W_rst_mclk = ~S_rst_mclk[2];
wire W_rst_vid  = ~S_rst_vid[2];

//--------------------------------------------------------------------------
// SD 控制器：整个工程只有这一份，音频链从它的扇区读口取数
//--------------------------------------------------------------------------
wire [31:0] W_sec_addr;
wire        W_sec_read;
wire [7:0]  W_sec_data;
wire        W_sec_valid;
wire        W_sec_end;
wire        W_sd_init_done;

sd_card_top #(
    .TOKEN_TIMEOUT_CYCLES (10_000_000),
    .SPI_TIMEOUT_CYCLES   (1_000_000),
    .SPI_LOW_SPEED_DIV    (248),
    .SPI_HIGH_SPEED_DIV   (0)
) u_sd (
    .clk                    (I_sd_clk),
    .rst                    (W_rst_sd),
    .read_cancel            (1'b0),
    .sd_sec_ready           (),
    .sd_sec_read_error      (),
    .SD_nCS                 (O_sd_ncs),
    .SD_DCLK                (O_sd_dclk),
    .SD_MOSI                (O_sd_mosi),
    .SD_MISO                (I_sd_miso),
    .sd_init_done           (W_sd_init_done),
    .sd_sec_read            (W_sec_read),
    .sd_sec_read_addr       (W_sec_addr),
    .sd_sec_read_data       (W_sec_data),
    .sd_sec_read_data_valid (W_sec_valid),
    .sd_sec_read_end        (W_sec_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (8'd0),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

//--------------------------------------------------------------------------
// WAV 播放链
//--------------------------------------------------------------------------
wire [31:0] W_file_size, W_frame_total, W_play_pos;
wire [3:0]  W_wav_state, W_wav_err_code;
wire        W_wav_ready, W_wav_error, W_wav_end, W_underrun;
wire [10:0] W_buf_level;

wav_audio_sd_top #(
    .START_SECTOR   (START_SECTOR),
    .MCLK_HZ        (MCLK_HZ),
    .pcm_bits       (24),
    .FIFO_DEPTH     (1024),
    .FIFO_addr_bits (10),
    .ACR_N          (6144)
) u_audio (
    .I_sd_clk        (I_sd_clk),
    .I_mclk          (I_mclk),
    .I_video_clk     (I_video_clk),
    .I_sd_rst        (W_rst_sd),
    .I_mclk_rst      (W_rst_mclk),
    .I_video_rst     (W_rst_vid),

    .I_play          (I_ctrl[0]),
    .I_stop          (I_ctrl[1]),
    .I_mute          (I_ctrl[2]),
    .I_loop          (I_ctrl[3]),

    .I_sd_init_done  (W_sd_init_done),
    .O_sd_sec_addr   (W_sec_addr),
    .O_sd_sec_read   (W_sec_read),
    .I_sd_sec_data   (W_sec_data),
    .I_sd_sec_valid  (W_sec_valid),
    .I_sd_sec_end    (W_sec_end),

    .O_audio_valid      (O_audio_valid),
    .O_audio_left_data  (O_audio_l),
    .O_audio_right_data (O_audio_r),
    .O_acr_valid        (O_acr_valid),
    .O_acr_cts          (O_acr_cts),
    .O_acr_n            (O_acr_n),

    .O_wav_ready        (W_wav_ready),
    .O_wav_error        (W_wav_error),
    .O_wav_error_code   (W_wav_err_code),
    .O_wav_state        (W_wav_state),
    .O_file_size        (W_file_size),
    .O_sample_rate      (),
    .O_channels         (),
    .O_bits             (),
    .O_frame_total      (W_frame_total),
    .O_play_pos         (W_play_pos),
    .O_play_end         (W_wav_end),
    .O_buf_level        (W_buf_level),
    .O_underrun         (W_underrun)
);

//--------------------------------------------------------------------------
// 视频扫描：640×480 @ 59.94 Hz（800×525 总时序，与 HDMI 核参数一致）
//   只需要 x/y/de 三个信号喂给 wave_painter；这里不产生 HS/VS，
//   因为 wave_painter 只关心有效区内的坐标。
//--------------------------------------------------------------------------
localparam integer H_ACT = 640, H_TOT = 800;
localparam integer V_ACT = 480, V_TOT = 525;

reg [11:0] S_hc, S_vc;

always @(posedge I_video_clk or posedge W_rst_vid) begin
    if (W_rst_vid) begin
        S_hc <= 12'd0;
        S_vc <= 12'd0;
    end
    else if (S_hc == (H_TOT - 1)) begin
        S_hc <= 12'd0;
        if (S_vc == (V_TOT - 1)) S_vc <= 12'd0;
        else                     S_vc <= S_vc + 12'd1;
    end
    else begin
        S_hc <= S_hc + 12'd1;
    end
end

wire W_pix_de = (S_hc < H_ACT) && (S_vc < V_ACT);

//--------------------------------------------------------------------------
// 波形绘制：直接用 O_audio_valid / 左声道（同在 video_clk 域，无需再跨域）
//--------------------------------------------------------------------------
wire        W_hit;
wire [23:0] W_rgb;
wire        W_de_d;
wire [7:0]  W_wr_ptr;
wire        W_rd_bank, W_capturing, W_bank_ready;
wire [31:0] W_smp_cnt, W_frame_cnt;

wave_painter #(
    .COL_W    (200),
    .ROW_H    (200),
    .DEPTH    (256),
    .ADDR_BITS(8),
    .X0       (20),
    .Y0       (240)
) u_wave (
    .I_clk       (I_video_clk),
    .I_rst       (W_rst_vid),

    .I_smp_valid (O_audio_valid),
    .I_smp_data  (O_audio_l),

    .I_pix_x     (S_hc[11:0]),
    .I_pix_y     (S_vc[11:0]),
    .I_pix_de    (W_pix_de),

    .O_pix_hit   (W_hit),
    .O_pix_rgb   (W_rgb),
    .O_pix_de_d  (W_de_d),

    .O_wr_ptr    (W_wr_ptr),
    .O_rd_bank   (W_rd_bank),
    .O_capturing (W_capturing),
    .O_bank_ready(W_bank_ready),
    .O_smp_cnt   (W_smp_cnt),
    .O_frame_cnt (W_frame_cnt)
);

assign O_pix_hit  = W_hit;
assign O_pix_rgb  = W_rgb;
assign O_pix_de_d = W_de_d;

//--------------------------------------------------------------------------
// 状态归约：32 位状态量不能直接引 pad（会吃掉几十个 IO），XOR 成 8 位
//--------------------------------------------------------------------------
assign O_dbg[0] = W_wav_ready;
assign O_dbg[1] = W_wav_error;
assign O_dbg[2] = W_underrun;
assign O_dbg[3] = W_rd_bank;
assign O_dbg[4] = W_capturing;
assign O_dbg[5] = ^W_wav_state;
assign O_dbg[6] = ^{W_wav_err_code, W_buf_level};
assign O_dbg[7] = ^{W_file_size, W_frame_total, W_play_pos, W_smp_cnt, W_frame_cnt,
                    W_wr_ptr, W_wav_end, W_bank_ready};

endmodule
