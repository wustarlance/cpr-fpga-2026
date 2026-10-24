`timescale 1ns/1ps
//=============================================================================
// audio_board_top.v —— WAV(SD) → HDMI 音频 的板级顶层（实机演示用）
//-----------------------------------------------------------------------------
// 定位：
//   这是"能出位流、能上板听到声音"的最小顶层。视频只画彩条 + 状态色块 +
//   FIFO 电平条，不接 CPR 主工程的图像链路，也不含 wave_painter（波形绘制）。
//   目的单一：把 rtl/audio 下这条 WAV 通路在真板子上跑起来。
//
// 复用（全部原样引用，未改动）：
//   ip/sys_pll.ipc                    50M → 100M sd_clk（SD/SPI + wav_reader）
//   ip/video_pll.ipc                  50M → 25M 像素 / 125M TMDS 5x
//   PLL_HDMI_AUDIO.ipc                50M → 12.295082M mclk（fs = MCLK/256）
//   hdmi_1_4b_transmitter_core_wrapper.enc.v + hdmi_phy_wrapper + lane_lvds_10_1
//   vendor/SD/sd_card_top.v           SPI 模式读扇区
//   rtl/audio/wav_audio_sd_top.v      WAV 解析 + PCM FIFO + ACR
//
// 三个时钟域（与参考工程一致，互异步）：
//   sd_clk   100 MHz   SD 扇区读、wav_reader、按键消抖
//   mclk     12.295082 MHz  48 kHz 帧节拍（pcm_frame_tick / pcm_player）
//   video_clk 25 MHz  像素扫描、PCM → HDMI、ACR
//
// 上电行为：PLL 全锁定 → 等 1 ms → 三个域各自同步释放复位 → 自动播放。
//   按键：KEY2 = 播放/暂停（翻转），KEY3 = 回到文件头（停止），KEY4 = 静音，
//         SW1 = 循环开关，KEY1(A2) = 全局复位。
//=============================================================================
module audio_board_top (
    /* ---- 时钟 / 复位 ---- */
    input  wire        clk,          // R7  50 MHz 有源晶振
    input  wire        rst_n,        // A2  KEY1，按下为低 → 全局复位

    /* ---- 控制 ---- */
    input  wire        key_play,     // B2  KEY2：播放 / 暂停
    input  wire        key_stop,     // B1  KEY3：回文件头
    input  wire        key_mute,     // C1  KEY4：静音开关
    input  wire [3:0]  dip_sw,       // C8/C7/C6/C5 = SW1..SW4（SW1 = 循环）

    /* ---- 指示 ---- */
    output wire [3:0]  led,          // A4/A3/C10/B12
    output wire        O_buzzer,     // H11 蜂鸣器（低电平响，需 SW5 拨到接通）

    /* ---- HDMI_B（唯一的声音出口：音频嵌在 TMDS 数据岛里） ---- */
    output wire        HDMI_CLK_P,   // C3
    output wire        HDMI_D0_P,    // G5
    output wire        HDMI_D1_P,    // F1
    output wire        HDMI_D2_P,    // E1
    output wire        HDMI_DDC_SCL, // P2
    inout  wire        HDMI_DDC_SDA, // R2

    /* ---- TF 卡（SPI 模式） ---- */
    output wire        sd_ncs,       // A12  SD_DAT3/CS
    output wire        sd_dclk,      // A14  SD_CLK
    output wire        sd_mosi,      // A13  SD_CMD/DI
    input  wire        sd_miso       // B14  SD_DAT0/DO
);

/* ========================================================================== */
/* 0. 时钟：三颗 PLL                                                          */
/* ========================================================================== */
wire        sd_clk;        // 100 MHz
wire        video_clk;     // 25 MHz
wire        hdmi_5x_clk;   // 125 MHz
wire        audio_mclk;    // 12.295082 MHz

wire sys_lock, video_lock, audio_pll_lock;

sys_pll u_sys_pll (
    .refclk   (clk),
    .clk0_out (sd_clk),          // 100 MHz
    .clk1_out (),                // 40 MHz（本工程不用 SDRAM）
    .clk2_out (),                // 40 MHz 180°（同上）
    .extlock  (sys_lock),
    .reset    (1'b0)
);

video_pll u_video_pll (
    .refclk   (clk),
    .clk0_out (video_clk),       // 25.000 MHz（640x480@60 标称 25.175，实际 59.5 Hz）
    .clk1_out (hdmi_5x_clk),     // 125 MHz
    .extlock  (video_lock),
    .reset    (1'b0)
);

PLL_HDMI_AUDIO u_audio_pll (
    .refclk   (clk),
    .reset    (1'b0),
    .extlock  (audio_pll_lock),
    .clk0_out (),
    .clk1_out (),
    .clk2_out (audio_mclk)       // 12.295082 MHz → fs = 48027 Hz
);

/* ========================================================================== */
/* 1. 复位：PLL 锁 + 1 ms 上电延时，再按域同步释放                            */
/* ========================================================================== */
wire all_locked    = sys_lock & video_lock & audio_pll_lock;
wire por_reset_n   = rst_n & all_locked;

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
            if (S_por_cnt == 20'd49_999) S_por_ready <= 1'b1;   // 50 MHz × 1 ms
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

// 下游模块沿用高有效复位
wire rst_sd    = ~sd_rst_n;
wire rst_video = ~video_rst_n;
wire rst_audio = ~audio_rst_n;

/* ========================================================================== */
/* 2. 按键消抖 + 控制（sd_clk 域，与 wav_audio_path 的控制口同域）            */
/* ========================================================================== */
// 每个键：2 级同步 → 稳定 20 ms 才认 → 下降沿（按下）出 1 拍脉冲
reg  [1:0]  S_kp_sync, S_ks_sync, S_km_sync;
reg         S_kp_st,   S_ks_st,   S_km_st;
reg         S_kp_st_d, S_ks_st_d, S_km_st_d;
reg  [20:0] S_kp_cnt,  S_ks_cnt,  S_km_cnt;

localparam [20:0] DB_MAX = 21'd1_999_999;   // 100 MHz × 20 ms

always @(posedge sd_clk or posedge rst_sd) begin
    if (rst_sd) begin
        S_kp_sync <= 2'b11; S_ks_sync <= 2'b11; S_km_sync <= 2'b11;
        S_kp_st   <= 1'b1;  S_ks_st   <= 1'b1;  S_km_st   <= 1'b1;
        S_kp_st_d <= 1'b1;  S_ks_st_d <= 1'b1;  S_km_st_d <= 1'b1;
        S_kp_cnt  <= 21'd0; S_ks_cnt  <= 21'd0; S_km_cnt  <= 21'd0;
    end
    else begin
        /* ---- KEY2：播放/暂停 ---- */
        S_kp_sync <= {S_kp_sync[0], key_play};
        if (S_kp_sync[1] != S_kp_st) begin
            if (S_kp_cnt == DB_MAX) begin S_kp_st <= S_kp_sync[1]; S_kp_cnt <= 21'd0; end
            else S_kp_cnt <= S_kp_cnt + 21'd1;
        end
        else S_kp_cnt <= 21'd0;
        S_kp_st_d <= S_kp_st;

        /* ---- KEY3：停止 ---- */
        S_ks_sync <= {S_ks_sync[0], key_stop};
        if (S_ks_sync[1] != S_ks_st) begin
            if (S_ks_cnt == DB_MAX) begin S_ks_st <= S_ks_sync[1]; S_ks_cnt <= 21'd0; end
            else S_ks_cnt <= S_ks_cnt + 21'd1;
        end
        else S_ks_cnt <= 21'd0;
        S_ks_st_d <= S_ks_st;

        /* ---- KEY4：静音 ---- */
        S_km_sync <= {S_km_sync[0], key_mute};
        if (S_km_sync[1] != S_km_st) begin
            if (S_km_cnt == DB_MAX) begin S_km_st <= S_km_sync[1]; S_km_cnt <= 21'd0; end
            else S_km_cnt <= S_km_cnt + 21'd1;
        end
        else S_km_cnt <= 21'd0;
        S_km_st_d <= S_km_st;
    end
end

wire W_play_press = S_kp_st_d & ~S_kp_st;   // 按下（1→0）那一拍
wire W_stop_press = S_ks_st_d & ~S_ks_st;
wire W_mute_press = S_km_st_d & ~S_km_st;

reg       S_play;
reg       S_mute;
reg       S_stop_pulse;

always @(posedge sd_clk or posedge rst_sd) begin
    if (rst_sd) begin
        S_play       <= 1'b1;      // 上电自动播放
        S_mute       <= 1'b0;
        S_stop_pulse <= 1'b0;
    end
    else begin
        S_stop_pulse <= W_stop_press;
        if (W_play_press) S_play <= ~S_play;
        if (W_stop_press) S_play <= 1'b1;   // 停止后回到播放态，从头再放
        if (W_mute_press) S_mute <= ~S_mute;
    end
end

wire W_loop = dip_sw[0];       // SW1 拨上（1）= 单文件循环

/* ========================================================================== */
/* 3. SD 控制器（SPI 模式，只读）                                             */
/* ========================================================================== */
wire [31:0] W_sec_addr;
wire        W_sec_read;
wire [7:0]  W_sec_data;
wire        W_sec_valid;
wire        W_sec_end;
wire        W_sd_init_done;

sd_card_top #(
    .SPI_LOW_SPEED_DIV  (248),   // 100 MHz / ((248+2)*2) = 200 kHz（初始化）
    .SPI_HIGH_SPEED_DIV (0)      // 100 MHz / ((0+2)*2)   = 25 MHz（读写）
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
/* 4. WAV 播放链路（rtl/audio，未改动）                                       */
/* ========================================================================== */
wire        W_audio_valid;
wire [23:0] W_audio_left;
wire [23:0] W_audio_right;
wire        W_acr_valid;
wire [19:0] W_acr_cts;
wire [19:0] W_acr_n;

wire        W_wav_ready;
wire        W_wav_error;
wire [3:0]  W_wav_error_code;
wire [3:0]  W_wav_state;
wire [31:0] W_file_size;
wire [31:0] W_sample_rate;
wire [15:0] W_channels;
wire [15:0] W_bits;
wire [31:0] W_frame_total;
wire [31:0] W_play_pos;
wire        W_play_end;
wire [10:0] W_buf_level;
wire        W_underrun;

wav_audio_sd_top #(
    // WAV 在卡上的首扇区：必须和 tools/burn_wav.py 用的 --lba 一致。
    // 默认 12000 是为了避开 BMP 镜像（LBA 0~11853）；只放音频的卡可改成 0 之后的
    // 实际位置，但一定要与烧卡时一致，否则读到的是别的东西（表现为 ERR 或杂音）。
    .START_SECTOR (32'd12000)
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
/* 5. 视频：640×480@59.5Hz 时序 + 彩条/状态内容                               */
/* ========================================================================== */
localparam [9:0] H_ACTIVE = 10'd640, H_FP = 10'd16, H_SYNC = 10'd96, H_BP = 10'd48;
localparam [9:0] H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP;      // 800
localparam [9:0] V_ACTIVE = 10'd480, V_FP = 10'd10, V_SYNC = 10'd2,  V_BP = 10'd33;
localparam [9:0] V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP;      // 525

reg [9:0] S_hcnt, S_vcnt;

always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) begin
        S_hcnt <= 10'd0;
        S_vcnt <= 10'd0;
    end
    else if (S_hcnt == H_TOTAL - 10'd1) begin
        S_hcnt <= 10'd0;
        S_vcnt <= (S_vcnt == V_TOTAL - 10'd1) ? 10'd0 : (S_vcnt + 10'd1);
    end
    else begin
        S_hcnt <= S_hcnt + 10'd1;
    end
end

wire W_vs = ~((S_vcnt >= (V_ACTIVE + V_FP)) &&
              (S_vcnt <  (V_ACTIVE + V_FP + V_SYNC)));
wire W_de = (S_hcnt < H_ACTIVE) && (S_vcnt < V_ACTIVE);

wire [9:0] W_x = S_hcnt;
wire [9:0] W_y = S_vcnt;

/* ---- 底色：8 条 75% 彩条，每条 80 像素 ---- */
reg [23:0] W_bar;
always @* begin
    if      (W_x <  10'd80) W_bar = 24'hF0F0F0;   // 白
    else if (W_x < 10'd160) W_bar = 24'hF0F000;   // 黄
    else if (W_x < 10'd240) W_bar = 24'h00F0F0;   // 青
    else if (W_x < 10'd320) W_bar = 24'h00F000;   // 绿
    else if (W_x < 10'd400) W_bar = 24'hF000F0;   // 品红
    else if (W_x < 10'd480) W_bar = 24'hF00000;   // 红
    else if (W_x < 10'd560) W_bar = 24'h0000F0;   // 蓝
    else                    W_bar = 24'h101010;   // 黑
end

/* ---- 状态色块（左上 32×32）：绿=有数据在放，黄=还没就绪，红=出错，紫=欠载 ---- */
reg [23:0] W_state_col;
always @* begin
    if (W_wav_error)                 W_state_col = 24'hF00000;
    else if (W_underrun)             W_state_col = 24'hF000F0;
    else if (!W_wav_ready)           W_state_col = 24'hF0F000;
    else                             W_state_col = 24'h00F000;
end

/* ---- 播放/暂停指示（右上 32×32） ---- */
wire [23:0] W_play_col = S_play ? 24'h00C000 : 24'h400000;

/* ---- FIFO 缓冲电平条（底部 12 行，宽度 = buf_level/2，0..512 像素） ---- */
wire [9:0] W_buf_px = {1'b0, W_buf_level[9:1]} + 10'd8;
wire       W_bar_on = (W_y >= 10'd452) && (W_y < 10'd464) &&
                      (W_x >= 10'd8)   && (W_x < 10'd528);

/* ---- 播放进度条（该行按 play_pos 的低位滚动，只做"在动"的可视证据） ---- */
wire [9:0] W_pos_px = {2'b00, W_play_pos[7:0]} << 1;      // 0..510
wire       W_pos_on = (W_y >= 10'd440) && (W_y < 10'd448) &&
                      (W_x >= 10'd8)   && (W_x < (10'd8 + W_pos_px));

/* ---- 合成 ---- */
reg [23:0] W_rgb;
always @* begin
    W_rgb = W_bar;
    if (W_bar_on)         W_rgb = (W_x < W_buf_px) ? 24'hFFFFFF : 24'h303030;
    if (W_pos_on)         W_rgb = 24'h00FFFF;
    if ((W_x >= 10'd8)  && (W_x < 10'd40) &&
        (W_y >= 10'd8)  && (W_y < 10'd40)) W_rgb = W_state_col;
    if ((W_x >= 10'd600) && (W_x < 10'd632) &&
        (W_y >= 10'd8)   && (W_y < 10'd40)) W_rgb = W_play_col;
    // 边框
    if ((W_x < 10'd2) || (W_x > 10'd637) || (W_y < 10'd2) || (W_y > 10'd477))
        W_rgb = 24'h202020;
end

/* ========================================================================== */
/* 6. RGB/DE → AXIS → HDMI 1.4b（含音频数据岛）                               */
/* ========================================================================== */
wire        W_axis_user;
wire        W_axis_valid;
wire        W_axis_last;
wire [23:0] W_axis_data;
wire        W_axis_ready;

video_rgb_to_axis_640x480 u_video_to_axis (
    .I_clk         (video_clk),
    .I_rst         (rst_video),
    .I_vs          (W_vs),
    .I_de          (W_de),
    .I_rgb         (W_rgb),
    .O_video_user  (W_axis_user),
    .O_video_valid (W_axis_valid),
    .O_video_last  (W_axis_last),
    .O_video_data  (W_axis_data)
);

wire        W_edid_trig;
wire        W_edid_valid;
wire [7:0]  W_edid_data;

startup_pulse #(
    .CNT_MAX (20'd100_000)
) u_edid_trig (
    .I_clk   (video_clk),
    .I_rst   (rst_video),
    .O_pulse (W_edid_trig)
);

wire [9:0] W_tmds_ch0, W_tmds_ch1, W_tmds_ch2, W_tmds_clk;

hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE            ( "EG"      ),
    .HTOTAL            ( 800       ),
    .HSA               ( 96        ),
    .HFP               ( 16        ),
    .HBP               ( 48        ),
    .HACTIVE           ( 640       ),
    .VTOTAL            ( 525       ),
    .VSA               ( 2         ),
    .VFP               ( 10        ),
    .VBP               ( 33        ),
    .VACTIVE           ( 480       ),
    .VIDEO_VIC         ( 1         ),
    .VIDEO_TPG         ( "Disable" ),
    .VIDEO_FORMAT      ( "RGB"     ),
    .AUDIO_SAMPLE_RATE ( "48K"     ),
    .IIC_SCL_DIV       ( 250       )
) u_hdmi_core (
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_video),
    .I_edid_read_trig   (W_edid_trig),
    .O_edid_read_valid  (W_edid_valid),
    .O_edid_read_data   (W_edid_data),

    .I_axis_s_user      (W_axis_user),
    .I_axis_s_valid     (W_axis_valid),
    .I_axis_s_last      (W_axis_last),
    .I_axis_s_data      (W_axis_data),
    .O_axis_s_ready     (W_axis_ready),

    .I_audio_valid      (W_audio_valid),
    .I_audio_left_data  (W_audio_left),
    .I_audio_right_data (W_audio_right),
    .I_acr_valid        (W_acr_valid),
    .I_acr_cts          (W_acr_cts),
    .I_acr_n            (W_acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (W_tmds_ch0),
    .O_ch1_tmds_data    (W_tmds_ch1),
    .O_ch2_tmds_data    (W_tmds_ch2),
    .O_clk_tmds_data    (W_tmds_clk)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi_phy (
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_video),
    .I_tmds_channel_0   (W_tmds_ch0),
    .I_tmds_channel_1   (W_tmds_ch1),
    .I_tmds_channel_2   (W_tmds_ch2),
    .I_tmds_channel_clk (W_tmds_clk),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

/* ========================================================================== */
/* 7. 蜂鸣器：一阶 Σ-Δ，把左声道 24 bit 变成 1 bit                           */
/* ========================================================================== */
// 板上唯一的"喇叭"就是这颗蜂鸣器（H11，低电平导通，SW5 拨下才接通）。
// 用 25 MHz 对 48 kHz 样本做一阶 Σ-Δ，过采样比 520，足够听清旋律；
// 它只是备选出口 —— 正常演示请用 HDMI 接带喇叭的显示器。
reg signed [24:0] S_ds_acc;
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) S_ds_acc <= 25'sd0;
    else if (W_audio_valid) S_ds_acc <= S_ds_acc + {{1{W_audio_left[23]}}, W_audio_left};
end
assign O_buzzer = ~S_ds_acc[24];

/* ========================================================================== */
/* 8. LED                                                                     */
/* ========================================================================== */
assign led[0] = S_play;        // 在放
assign led[1] = S_mute;        // 静音
assign led[2] = W_wav_error;   // 解析/读卡出错
assign led[3] = W_wav_ready;   // WAV 头已解析

endmodule
