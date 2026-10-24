`timescale 1ns/1ps
//=============================================================================
// audio_board_bringup_top.v —— 不依赖加密 IP 的"最小上板"顶层
//-----------------------------------------------------------------------------
// 为什么还要这一版：
//   教学资料里的 HDMI 1.4b 发射核是 IEEE-1735 加密代码（`pragma protect /
//   AES128-CBC / anlogic-rsa-001`）。本机装的 TD 6.2.1（V6.2.168116）解析不了
//   这段加密块 —— 连厂商自带的 HDMI1.4b_Transmitter_v1.0.al 也报
//   HDL-8007 "unexpected non-printable character"，所以本机现在**生成不出**
//   带 HDMI 的位流（需要 TD 6.2.1 SP1 / 6.2.178840）。
//
//   这一版把视频/HDMI 整段拿掉，只用板上本来就有的东西验收音频链路：
//     7 段数码管  显示 WAV 状态、错误码、以及 48 kHz 帧计数（在跳=在放）
//     4 个 LED    在放 / 静音 / 出错 / 已解析
//     蜂鸣器      一阶 Σ-Δ 把左声道 24 bit 变 1 bit，能听出旋律
//     TF 卡       仍走 SPI 读扇区，和最终方案完全一样
//
//   等 SP1 到位后直接换 audio_board_top（HDMI 版），其它模块一行不用改。
//
// 时钟：仍然要三颗（wav_audio_path 的 PCM 输出在视频域里做跨域握手，
//       没有 video_clk 这一级，O_audio_valid 永远不会出来）。
//       video_clk 只做内部时钟，不引到任何引脚。
//=============================================================================
module audio_board_bringup_top (
    input  wire        clk,          // R7  50 MHz
    input  wire        rst_n,        // A2  KEY1

    input  wire        key_play,     // B2  KEY2
    input  wire        key_stop,     // B1  KEY3
    input  wire        key_mute,     // C1  KEY4
    input  wire [3:0]  dip_sw,       // C8/C7/C6/C5

    output wire [3:0]  led,          // A4/A3/C10/B12
    output wire [7:0]  seg_sel,      // F16/E16/E12/E10/C13/F10/E11/D11
    output wire [7:0]  seg_data,     // C15/C16/B6/A5/B5/A8/A7/A6
    output wire        O_buzzer,     // H11

    output wire        sd_ncs,       // A12
    output wire        sd_dclk,      // A14
    output wire        sd_mosi,      // A13
    input  wire        sd_miso       // B14
);

/* ========================================================================== */
/* 0. 时钟                                                                    */
/* ========================================================================== */
wire sd_clk, video_clk, audio_mclk;
wire sys_lock, video_lock, audio_pll_lock;

sys_pll u_sys_pll (
    .refclk   (clk),
    .clk0_out (sd_clk),          // 100 MHz
    .clk1_out (),
    .clk2_out (),
    .extlock  (sys_lock),
    .reset    (1'b0)
);

video_pll u_video_pll (
    .refclk   (clk),
    .clk0_out (video_clk),       // 25 MHz，仅内部用（PCM 跨域 + ACR）
    .clk1_out (),                // 125 MHz，本版不用
    .extlock  (video_lock),
    .reset    (1'b0)
);

PLL_HDMI_AUDIO u_audio_pll (
    .refclk   (clk),
    .reset    (1'b0),
    .extlock  (audio_pll_lock),
    .clk0_out (),
    .clk1_out (),
    .clk2_out (audio_mclk)       // 12.295082 MHz
);

/* ========================================================================== */
/* 1. 复位                                                                    */
/* ========================================================================== */
wire all_locked  = sys_lock & video_lock & audio_pll_lock;
wire por_reset_n = rst_n & all_locked;

reg [1:0]  S_lock_sync;
reg [19:0] S_por_cnt;
reg        S_por_ready;

always @(posedge clk or negedge por_reset_n) begin
    if (!por_reset_n) begin
        S_lock_sync <= 2'b00;
        S_por_cnt   <= 20'd0;
        S_por_ready <= 1'b0;
    end
    else begin
        S_lock_sync <= {S_lock_sync[0], all_locked};
        if (!S_lock_sync[1]) begin
            S_por_cnt   <= 20'd0;
            S_por_ready <= 1'b0;
        end
        else if (!S_por_ready) begin
            if (S_por_cnt == 20'd49_999) S_por_ready <= 1'b1;   // 1 ms @50 MHz
            else S_por_cnt <= S_por_cnt + 20'd1;
        end
    end
end

wire sd_rst_n, video_rst_n, audio_rst_n;
reset_release u_sd_reset    (.clk(sd_clk),    .reset_n_async(por_reset_n),
                             .rst_n(sd_rst_n),    .ready(S_por_ready));
reset_release u_video_reset (.clk(video_clk), .reset_n_async(por_reset_n),
                             .rst_n(video_rst_n), .ready(S_por_ready));
reset_release u_audio_reset (.clk(audio_mclk),.reset_n_async(por_reset_n),
                             .rst_n(audio_rst_n), .ready(S_por_ready));

wire rst_sd    = ~sd_rst_n;
wire rst_video = ~video_rst_n;
wire rst_audio = ~audio_rst_n;

/* ========================================================================== */
/* 2. 按键消抖 + 控制（sd_clk 域）                                            */
/* ========================================================================== */
reg  [1:0]  S_kp_sync, S_ks_sync, S_km_sync;
reg         S_kp_st,   S_ks_st,   S_km_st;
reg         S_kp_st_d, S_ks_st_d, S_km_st_d;
reg  [20:0] S_kp_cnt,  S_ks_cnt,  S_km_cnt;

localparam [20:0] DB_MAX = 21'd1_999_999;   // 20 ms @100 MHz

always @(posedge sd_clk or posedge rst_sd) begin
    if (rst_sd) begin
        S_kp_sync <= 2'b11; S_ks_sync <= 2'b11; S_km_sync <= 2'b11;
        S_kp_st   <= 1'b1;  S_ks_st   <= 1'b1;  S_km_st   <= 1'b1;
        S_kp_st_d <= 1'b1;  S_ks_st_d <= 1'b1;  S_km_st_d <= 1'b1;
        S_kp_cnt  <= 21'd0; S_ks_cnt  <= 21'd0; S_km_cnt  <= 21'd0;
    end
    else begin
        S_kp_sync <= {S_kp_sync[0], key_play};
        if (S_kp_sync[1] != S_kp_st) begin
            if (S_kp_cnt == DB_MAX) begin S_kp_st <= S_kp_sync[1]; S_kp_cnt <= 21'd0; end
            else S_kp_cnt <= S_kp_cnt + 21'd1;
        end
        else S_kp_cnt <= 21'd0;
        S_kp_st_d <= S_kp_st;

        S_ks_sync <= {S_ks_sync[0], key_stop};
        if (S_ks_sync[1] != S_ks_st) begin
            if (S_ks_cnt == DB_MAX) begin S_ks_st <= S_ks_sync[1]; S_ks_cnt <= 21'd0; end
            else S_ks_cnt <= S_ks_cnt + 21'd1;
        end
        else S_ks_cnt <= 21'd0;
        S_ks_st_d <= S_ks_st;

        S_km_sync <= {S_km_sync[0], key_mute};
        if (S_km_sync[1] != S_km_st) begin
            if (S_km_cnt == DB_MAX) begin S_km_st <= S_km_sync[1]; S_km_cnt <= 21'd0; end
            else S_km_cnt <= S_km_cnt + 21'd1;
        end
        else S_km_cnt <= 21'd0;
        S_km_st_d <= S_km_st;
    end
end

wire W_play_press = S_kp_st_d & ~S_kp_st;
wire W_stop_press = S_ks_st_d & ~S_ks_st;
wire W_mute_press = S_km_st_d & ~S_km_st;

reg S_play, S_mute, S_stop_pulse;

always @(posedge sd_clk or posedge rst_sd) begin
    if (rst_sd) begin
        S_play       <= 1'b1;
        S_mute       <= 1'b0;
        S_stop_pulse <= 1'b0;
    end
    else begin
        S_stop_pulse <= W_stop_press;
        if (W_play_press) S_play <= ~S_play;
        if (W_stop_press) S_play <= 1'b1;
        if (W_mute_press) S_mute <= ~S_mute;
    end
end

wire W_loop = dip_sw[0];

/* ========================================================================== */
/* 3. SD 控制器                                                               */
/* ========================================================================== */
wire [31:0] W_sec_addr;
wire        W_sec_read;
wire [7:0]  W_sec_data;
wire        W_sec_valid;
wire        W_sec_end;
wire        W_sd_init_done;

sd_card_top #(
    .SPI_LOW_SPEED_DIV  (248),
    .SPI_HIGH_SPEED_DIV (0)
) u_sd (
    .clk                    (sd_clk),
    .rst                    (rst_sd),
    .read_cancel            (1'b0),
    .sd_sec_ready           (),
    .sd_sec_read_error      (),
    .SD_nCS                 (sd_ncs),
    .SD_DCLK                (sd_dclk),
    .SD_MOSI                (sd_mosi),
    .SD_MISO                (sd_miso),
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

/* ========================================================================== */
/* 4. WAV 播放链路                                                            */
/* ========================================================================== */
wire        W_audio_valid;
wire [23:0] W_audio_left;
wire [23:0] W_audio_right;
wire        W_acr_valid;
wire [19:0] W_acr_cts, W_acr_n;

wire        W_wav_ready;
wire        W_wav_error;
wire [3:0]  W_wav_error_code;
wire [3:0]  W_wav_state;
wire [31:0] W_file_size;
wire [31:0] W_sample_rate;
wire [15:0] W_channels, W_bits;
wire [31:0] W_frame_total;
wire [31:0] W_play_pos;
wire        W_play_end;
wire [10:0] W_buf_level;
wire        W_underrun;

wav_audio_sd_top #(
    .START_SECTOR (32'd12000)     // 与 tools/burn_wav.py --lba 必须一致
) u_audio (
    .I_sd_clk        (sd_clk),
    .I_mclk          (audio_mclk),
    .I_video_clk     (video_clk),
    .I_sd_rst        (rst_sd),
    .I_mclk_rst      (rst_audio),
    .I_video_rst     (rst_video),

    .I_play          (S_play),
    .I_stop          (S_stop_pulse),
    .I_mute          (S_mute),
    .I_loop          (W_loop),

    .I_sd_init_done  (W_sd_init_done),
    .O_sd_sec_addr   (W_sec_addr),
    .O_sd_sec_read   (W_sec_read),
    .I_sd_sec_data   (W_sec_data),
    .I_sd_sec_valid  (W_sec_valid),
    .I_sd_sec_end    (W_sec_end),

    .O_audio_valid      (W_audio_valid),
    .O_audio_left_data  (W_audio_left),
    .O_audio_right_data (W_audio_right),
    .O_acr_valid        (W_acr_valid),
    .O_acr_cts          (W_acr_cts),
    .O_acr_n            (W_acr_n),

    .O_wav_ready      (W_wav_ready),
    .O_wav_error      (W_wav_error),
    .O_wav_error_code (W_wav_error_code),
    .O_wav_state      (W_wav_state),
    .O_file_size      (W_file_size),
    .O_sample_rate    (W_sample_rate),
    .O_channels       (W_channels),
    .O_bits           (W_bits),
    .O_frame_total    (W_frame_total),
    .O_play_pos       (W_play_pos),
    .O_play_end       (W_play_end),
    .O_buf_level      (W_buf_level),
    .O_underrun       (W_underrun)
);

/* ========================================================================== */
/* 5. 蜂鸣器：一阶 Σ-Δ（video_clk 25 MHz 对 48 kHz，过采样 520）              */
/* ========================================================================== */
reg signed [24:0] S_ds_acc;
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) S_ds_acc <= 25'sd0;
    else if (W_audio_valid) S_ds_acc <= S_ds_acc + {{1{W_audio_left[23]}}, W_audio_left};
end
assign O_buzzer = ~S_ds_acc[24];

/* ========================================================================== */
/* 6. 数码管：状态 / 错误码 / 48 kHz 帧计数                                   */
/* ========================================================================== */
// 每来一帧 PCM 就 +1，肉眼看到末几位在跳 → 说明 SD→FIFO→PCM 全程在跑。
reg [23:0] S_frame_cnt;
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) S_frame_cnt <= 24'd0;
    else if (W_audio_valid) S_frame_cnt <= S_frame_cnt + 24'd1;
end

// 4 bit → 共阳 7 段（段码低有效，bit7 = 小数点，给 1 表示熄灭）
function [7:0] hex_seg;
    input [3:0] v;
    begin
        case (v)
            4'h0: hex_seg = {1'b1, 7'b100_0000};
            4'h1: hex_seg = {1'b1, 7'b111_1001};
            4'h2: hex_seg = {1'b1, 7'b010_0100};
            4'h3: hex_seg = {1'b1, 7'b011_0000};
            4'h4: hex_seg = {1'b1, 7'b001_1001};
            4'h5: hex_seg = {1'b1, 7'b001_0010};
            4'h6: hex_seg = {1'b1, 7'b000_0010};
            4'h7: hex_seg = {1'b1, 7'b111_1000};
            4'h8: hex_seg = {1'b1, 7'b000_0000};
            4'h9: hex_seg = {1'b1, 7'b001_0000};
            4'hA: hex_seg = {1'b1, 7'b000_1000};
            4'hB: hex_seg = {1'b1, 7'b000_0011};
            4'hC: hex_seg = {1'b1, 7'b100_0110};
            4'hD: hex_seg = {1'b1, 7'b010_0001};
            4'hE: hex_seg = {1'b1, 7'b000_0110};
            default: hex_seg = {1'b1, 7'b000_1110};
        endcase
    end
endfunction

localparam [7:0] SEG_BLANK = 8'hFF;

// 显示位序（左起）：state | err | 帧计数[23:20] … [3:0]
wire [7:0] W_d0 = hex_seg(W_wav_state);
wire [7:0] W_d1 = hex_seg(W_wav_error_code);
wire [7:0] W_d2 = S_frame_cnt[23:20] ? hex_seg(S_frame_cnt[23:20]) : SEG_BLANK;
wire [7:0] W_d3 = hex_seg(S_frame_cnt[19:16]);
wire [7:0] W_d4 = hex_seg(S_frame_cnt[15:12]);
wire [7:0] W_d5 = hex_seg(S_frame_cnt[11:8]);
wire [7:0] W_d6 = hex_seg(S_frame_cnt[7:4]);
wire [7:0] W_d7 = hex_seg(S_frame_cnt[3:0]);

cpr_seg_scan #(
    .CLK_FREQ (100_000_000)      // 用 sd_clk 扫描，与主工程 50 MHz 只是刷新快慢不同
) u_seg (
    .clk     (sd_clk),
    .rst_n   (sd_rst_n),
    .seg_sel (seg_sel),
    .seg_data(seg_data),
    .digit0  (W_d0), .digit1 (W_d1), .digit2 (W_d2), .digit3 (W_d3),
    .digit4  (W_d4), .digit5 (W_d5), .digit6 (W_d6), .digit7 (W_d7)
);

/* ========================================================================== */
/* 7. LED                                                                     */
/* ========================================================================== */
assign led[0] = S_play;
assign led[1] = S_mute;
assign led[2] = W_wav_error;
assign led[3] = W_wav_ready;

endmodule
