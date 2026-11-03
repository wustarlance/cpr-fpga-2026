
// Default top is the board-button demo. top_adc selects the internal ADC path.
module top #(
    parameter USE_EXTERNAL_IO = 1,
    parameter USE_ADC = 0,
    // 非 4:3 源图的模糊背景：缩略图面积平均 + 3x3 盒式模糊 + 双线性放大
    parameter BLUR_BACKGROUND = 1,
    parameter integer BG_BRIGHTNESS_NUM = 3,
    parameter integer BG_BRIGHTNESS_SHIFT = 2,
    parameter ENABLE_AUDIO = 1,
    parameter ENABLE_AUDIO_VISUALIZATION = 1,
    parameter ENABLE_SMOOTH_TRANSITIONS = 1,
    // 自动展播（模式 2）每页停留秒数。改这个数必须重新综合。
    parameter integer AUTO_DWELL_S = 5,
    parameter UI_LANGUAGE_ZH = 1,
    // 训练音源使用片内 heartbeat_synth，不读取 TF 卡。
    // BEAT_GATE 默认关闭；节拍指示仍保留。
    parameter BEAT_GATE = 0,
    parameter [1:0] TRAINING_PAGE_INDEX = 2'd1,
    parameter [11:0] RELEASE_BASELINE = 12'd3000,
    parameter [11:0] TRIGGER_LEVEL = 12'd150,
    parameter [11:0] RELEASE_LEVEL = 12'd100,
    parameter [11:0] TARGET_LOW = 12'd800,
    parameter [11:0] TARGET_HIGH = 12'd1600,
    // 板载 LED 高电平点亮；共阳数码管的段码低电平点亮。
    parameter LED_ACTIVE_LOW = 0
)(
    input                       clk,
    input                       rst_n,
    input                       key1,           // 手动下一张
    input                       key3,           // KEY3 (B1), previous
    input wire [3:0]             dip_sw,         // 演示模式触点图案；SW4 同时用于音频暂停
    input wire [4:0]             ext_keys_n,     // mode/prev/next/brightness/session clear
    // 外接面板接 J1 奇数脚 13~25，按下为低电平。
    // K1~K5 与板载按键并存；K6 调对比度，K7 切字幕；K8 未使用。
    input wire [6:0]             key_panel_n,
    input wire [3:0]             depth_sw_n,     // cumulative contacts, close to GND
    input                       key2,           // KEY4 (C1), mode

    output [7:0]                seg_sel,      // 位号 = 物理顺序：seg_sel[0] 为左起第 1 位
    output [7:0]                seg_data,
    output wire [3:0]           led,            // LED1..4 = A4 / A3 / C10 / B12，调试指示

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso
);

localparam MEM_DATA_BITS = 32;
localparam ADDR_BITS     = 21;
localparam BUSRT_BITS    = 10;
localparam FRAME_PIXELS  = 21'd307200;   // 640*480
localparam BUF0_ADDR     = 24'd0;
localparam BUF1_ADDR     = FRAME_PIXELS;
localparam BUF2_ADDR     = FRAME_PIXELS * 2;
localparam BUF3_ADDR     = FRAME_PIXELS * 3;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data_raw;
wire [23:0] vout_data;
wire        display_valid;
wire        boot_load_done_sd;

wire [3:0]  state_code;
wire [6:0]  seg_data_0;

wire        video_read_req;
wire        video_read_req_ack;
wire        video_read_en;
wire [31:0] video_read_data;

wire        sd_card_write_en;
wire        sd_card_pixel_ready;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
wire        frame_write_finish;
reg         frame_write_toggle_mem;

wire [1:0]  write_buf_idx;
wire [1:0]  disp_buf_idx;
wire [1:0] active_read_idx;
wire publish_req, publish_done, read_frame_start;
wire publish_raw, publish_fade, fade_request, fade_ready;
wire rst_sd; // Declare before use inside the generate block (no local implicit net).
generate if (ENABLE_SMOOTH_TRANSITIONS) begin: g_smooth_publish
    cpr_transition_publish u_transition_publish(
        .clk(sd_card_clk), .rst(rst_sd), .publish_in(publish_raw),
        .smooth_in(publish_fade), .publish_done(publish_done),
        .fade_ready_async(fade_ready), .fade_request(fade_request),
        .publish_out(publish_req));
end else begin: g_direct_publish
    assign publish_req=publish_raw;
    assign fade_request=1'b0;
end endgenerate


wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

wire hs_0;
wire vs_0;
wire de_0;

// HDMI 1.4b 音频发射相关
wire        audio_pll_lock;
wire        audio_mclk;
wire        audio_i2s_bclk;
wire        audio_i2s_lrck;
wire        audio_i2s_dout;
wire        audio_valid;
wire        audio_output_valid;
wire [23:0] audio_left_data;
wire [23:0] audio_right_data;
wire        acr_valid;
wire        acr_output_valid;
wire [19:0] acr_cts;
wire [19:0] acr_n;

wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

// 统一复位：TF 图像链路 + HDMI 音频链路
wire sys_lock, video_lock;
wire all_plls_locked = sys_lock && video_lock && audio_pll_lock;
wire por_reset_n = rst_n && all_plls_locked;
reg [1:0] lock_sync;
reg [19:0] por_count = 0;
reg por_ready = 0;
always @(posedge clk or negedge por_reset_n) begin
    if (!por_reset_n) begin lock_sync <= 0; por_count <= 0; por_ready <= 0; end
    else begin
        lock_sync <= {lock_sync[0],all_plls_locked};
        if (!lock_sync[1]) begin por_count <= 0; por_ready <= 0; end
        else if (!por_ready) begin
            if (por_count == 20'd999999) por_ready <= 1;
            else por_count <= por_count + 1'b1;
        end
    end
end
wire app_rst_n, sd_rst_n, mem_rst_n, audio_rst_n;
// Start the continuous HDMI raster/BRAM logo as soon as its own PLL is locked.
// Storage, application and audio retain the existing all-PLL + 20 ms startup.
// Every video pipeline stage uses this same reset: there is no raster switch
// when the media path becomes ready, so the receiver need not lock again.
wire video_out_rst_n;
wire rst_video = ~video_out_rst_n;
// Constant readiness needs no por_ready CDC exception. Keep this separate
// from the four u_*reset instances qualified by the 50 MHz readiness flag.
reset_release u_video_release(.clk(video_clk),
                           .reset_n_async(rst_n && video_lock),
                           .rst_n(video_out_rst_n),
                           .ready(1'b1));
assign rst_sd = ~sd_rst_n;
wire rst_mem = ~mem_rst_n;
wire rst_audio = ~audio_rst_n;
reset_release u_app_reset(.clk           (video_clk),
                          .reset_n_async (por_reset_n),
                          .rst_n         (app_rst_n),
                          .ready         (por_ready));
reset_release u_sd_reset(.clk           (sd_card_clk),
                         .reset_n_async (por_reset_n),
                         .rst_n         (sd_rst_n),
                         .ready         (por_ready));
reset_release u_mem_reset(.clk           (ext_mem_clk),
                          .reset_n_async (por_reset_n),
                          .rst_n         (mem_rst_n),
                          .ready         (por_ready));
reset_release u_audio_reset(.clk           (audio_mclk),
                            .reset_n_async (por_reset_n),
                            .rst_n         (audio_rst_n),
                            .ready         (por_ready));
frame_buffer_publish u_frame_publish(
    .src_clk      (sd_card_clk),
    .src_rst_n    (sd_rst_n),
    .publish      (publish_req),
    .buffer_index (disp_buf_idx),
    .busy         (),
    .done         (publish_done),
    .mem_clk      (ext_mem_clk),
    .mem_rst_n    (mem_rst_n),
    .frame_start  (read_frame_start),
    .active_index (active_read_idx));

wire tick_ms, next_key_n, prev_key_n, auto_enable, training_enabled;
wire [1:0] app_mode, brightness_level;
wire [31:0] press_count, rotate_remaining_ms;
wire [15:0] interval_ms, pause_ms;
wire rate_valid, pause_warning, rotate_due, beat_event, compression_event, sensor_fault;
wire [1:0] rate_grade, depth_grade;
wire [7:0] bpm_approx;
wire bpm_valid;
wire clear_session, adc_peak_event, adc_path_fault;
wire [1:0] adc_peak_grade;
reg [5:0] beat_hold_ms;
wire [5:0] app_keys_level;
wire subtitle_on;                    // K7 字幕开关（默认开）
wire [11:0] page_status_sd, page_status_video;
page_status_cdc u_page_status(
    .src_clk(sd_card_clk), .src_rst_n(sd_rst_n), .status(page_status_sd),
    .dst_clk(video_clk), .dst_rst_n(app_rst_n), .video_status(page_status_video));
// 板载、扩展口与面板按键统一为高有效，再按位相或。
// 板载按键不受 USE_EXTERNAL_IO 屏蔽；KEY1 仍用于复位。
// 字幕占应用 bit5，只由面板 K7 提供。
wire [5:0] onboard_keys = {1'b0, ~key1, ~key3, ~key2};
// Application bit5 is subtitle, not physical K6. K6 remains contrast-only.
wire [5:0] panel_keys   = {~key_panel_n[6], ~key_panel_n[4:0]};
wire [5:0] app_keys_raw;
key_source_merge u_key_merge(
    .onboard_keys (onboard_keys),
    .panel_keys   ({1'b0, (USE_EXTERNAL_IO ? ~ext_keys_n : 5'b00000)} | panel_keys),
    .keys         (app_keys_raw));
// 板卡演示时按压键配合 dip_sw 生成触点码；全零拨码取目标档。
// 外接模式直接读取 depth_sw_n，机械与压力标定由外部完成。
wire [3:0] app_depth_raw = USE_EXTERNAL_IO ? ~depth_sw_n :
    ((!key1) ? ((dip_sw == 0) ? 4'b0011 : dip_sw) : 4'b0000);
cpr_control #(.USE_PRESS_EVENTS(USE_ADC)) u_control(
    .clk                 (video_clk),
    .rst_n               (app_rst_n),
    .raw_keys            (app_keys_raw),
    .raw_depth           (app_depth_raw),
    .tick_ms             (tick_ms),
    .mode                (app_mode),
    .brightness_level    (brightness_level),
    .keys_level          (app_keys_level),
    .depth_level         (),
    .next_key_n          (next_key_n),
    .prev_key_n          (prev_key_n),
    .auto_enable         (auto_enable),
    .training_enabled    (training_enabled),
    .auto_run            (),
    .press_count         (press_count),
    .interval_ms         (interval_ms),
    .rate_valid          (rate_valid),
    .rate_grade          (rate_grade),
    .depth_grade         (depth_grade),
    .pause_ms            (pause_ms),
    .pause_warning       (pause_warning),
    .rotate_remaining_ms (rotate_remaining_ms),
    .rotate_due          (rotate_due),
    .beat_event          (beat_event),
    .compression_event   (compression_event),
    .sensor_fault        (sensor_fault),
    .bpm_approx          (bpm_approx),
    .bpm_valid           (bpm_valid),
    .press_event         (adc_peak_event),
    .press_grade         (adc_peak_grade),
    .press_fault         (adc_path_fault),
    .subtitle_on         (subtitle_on),
    .clear_session       (clear_session));

// USE_ADC 在综合期选择采样链；演示顶层不实例化 ADC。
generate
    if (USE_ADC) begin : g_adc
        wire adc_soc, adc_pd, adc_eoc;
        wire [2:0] adc_channel;
        wire [11:0] adc_dout;
        // EG_PHY_ADC 使用专用模拟 pad：CH4 为 M12，经板上电阻网络接 J2-35；VREF 为 L11。
        // 模拟 pad 不配置为普通数字端口，参考与输入电压仍需实测。
        // ADC 复用音频 PLL 的 12.295082 MHz 时钟。
        EG_PHY_ADC #(.CH4("ENABLE"), .VREF("ENABLE")) u_adc (
            .clk  (audio_mclk),
            .pd   (adc_pd),
            .s    (adc_channel),
            .soc  (adc_soc),
            .eoc  (adc_eoc),
            .dout (adc_dout));
        cpr_sensor_path #(
            .ADC_CLK_HZ       (12295082),
            .SAMPLE_HZ        (200000),
            .CHANNEL          (4),
            .RELEASE_BASELINE (RELEASE_BASELINE),
            .TRIGGER_LEVEL    (TRIGGER_LEVEL),
            .RELEASE_LEVEL    (RELEASE_LEVEL),
            .TARGET_LOW       (TARGET_LOW),
            .TARGET_HIGH(TARGET_HIGH)
        ) u_sensor (
            .adc_clk       (audio_mclk),
            .adc_rst_n     (audio_rst_n),
            .app_clk       (video_clk),
            .app_rst_n     (app_rst_n),
            .adc_eoc       (adc_eoc),
            .adc_dout      (adc_dout),
            .adc_soc       (adc_soc),
            .adc_pd        (adc_pd),
            .adc_channel   (adc_channel),
            .enabled       (training_enabled),
            .clear_session (clear_session),
            .peak_event    (adc_peak_event),
            .peak_grade    (adc_peak_grade),
            .peak_value    (),
            .raw_valid     (),
            .raw_data      (),
            .sensor_fault  (adc_path_fault));
    end else begin : g_demo
        assign adc_peak_event = 1'b0;
        assign adc_peak_grade = 2'd0;
        assign adc_path_fault = 1'b0;
    end
endgenerate
always @(posedge video_clk or negedge app_rst_n) begin
    if (!app_rst_n) beat_hold_ms <= 0;
    else if (!training_enabled) beat_hold_ms <= 0;
    else if (beat_event) beat_hold_ms <= 40;
    else if (tick_ms && beat_hold_ms != 0) beat_hold_ms <= beat_hold_ms - 1'b1;
end
wire audio_gate = BEAT_GATE ? ((app_mode != 2) || (beat_hold_ms != 0)) : 1'b1;
wire splash_on;
reg media_frame_started, media_audio_ready;
reg media_vs_q;
wire visual_vs, visual_de;
reg [1:0] display_valid_sync;
// Share the final gated PCM words between HDMI and its on-screen monitor.
// Keep sample-valid/ACR running with silence during the logo. Gate both the
// player and these final words, including delayed PCM and the training source.
wire media_audio_enable = media_audio_ready && !splash_on && app_rst_n &&
                          display_valid_sync[1];
wire [23:0] hdmi_audio_left = (ENABLE_AUDIO && audio_gate && media_audio_enable) ? audio_left_data : 24'd0;
wire [23:0] hdmi_audio_right = (ENABLE_AUDIO && audio_gate && media_audio_enable) ? audio_right_data : 24'd0;
assign audio_output_valid = ENABLE_AUDIO ? audio_valid : 1'b0;
assign acr_output_valid = ENABLE_AUDIO ? acr_valid : 1'b0;
reg [1:0] boot_load_done_sync;
reg       boot_splash_released;
reg [1:0] brightness_video;
reg brightness_vs_d;
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) begin brightness_video <= 3; brightness_vs_d <= 1; end
    else begin
        brightness_vs_d <= vs;
        if (brightness_vs_d && !vs) brightness_video <= brightness_level;
    end
end
wire [2:0] contrast_level;
reg [2:0] contrast_video;
// K6 单独调节对比度，拨码不参与。
contrast_controls u_contrast_controls(
    .clk(video_clk), .rst_n(app_rst_n), .tick_ms(tick_ms),
    .raw_key     (~key_panel_n[5]),          // K6：对比度，按下为低电平
    .contrast_level(contrast_level));
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) contrast_video <= 3'd3;   // 100 %：与 contrast_controls 的复位档一致
    else if (brightness_vs_d && !vs) contrast_video <= contrast_level;
end
wire [23:0] app_rgb, adjusted_rgb, contrasted_rgb, picture_rgb;
wire picture_vs, picture_de;
// 亮度与对比度作用于可视化后的整屏像素，包括 OSD。
// 两级均为组合逻辑，不增加像素延迟；vs/de 直通。
wire [23:0] picture_src_rgb = display_valid_sync[1] ? vout_data_raw : 24'h102030;
generate if (ENABLE_SMOOTH_TRANSITIONS) begin: g_slide_fade
    cpr_slide_fade u_fade(
        .clk(video_clk), .rst(rst_video), .request_async(fade_request),
        .vs(vs), .de(de), .rgb(picture_src_rgb),
        .ready(fade_ready), .out_vs(picture_vs), .out_de(picture_de),
        .out_rgb(picture_rgb), .gain());
end else begin: g_no_slide_fade
    assign picture_rgb=picture_src_rgb;
    assign picture_vs=vs;
    assign picture_de=de;
    assign fade_ready=1'b1;
end endgenerate
cpr_overlay #(.UNCALIBRATED_PRESSURE(USE_ADC), .PAGE_STATUS_ENABLE(1),
              .CHINESE_UI(UI_LANGUAGE_ZH)) u_overlay(
    .clk (video_clk),
    .rst (rst_video),
    .vs  (picture_vs),
    .de  (picture_de),
    .rgb(picture_rgb),
    .page_status         (page_status_video),
    .contrast_level      (contrast_level),
    .auto_running        (auto_enable),
    .mode                (app_mode),
    .count               (press_count),
    .rate                (rate_grade),
    .depth_grade         (depth_grade),
    .interval_ms         (interval_ms),
    .pause_ms            (pause_ms),
    .rotate_remaining_ms (rotate_remaining_ms),
    .bpm                 (bpm_approx),
    .bpm_valid           (bpm_valid),
    .sensor_fault        (sensor_fault | adc_path_fault),
    .brightness_level    (brightness_level),
    .subtitle_en         (subtitle_on),
    .pause_warning       (pause_warning),
    .rotate_due          (rotate_due),
    .beat                (beat_hold_ms != 0),
    .out_rgb             (app_rgb));
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) begin
        display_valid_sync <= 0;
        boot_load_done_sync <= 0;
        boot_splash_released <= 0;
    end else begin
        display_valid_sync <= {display_valid_sync[0],display_valid};
        boot_load_done_sync <= {boot_load_done_sync[0],boot_load_done_sd};
        if (!app_rst_n) boot_splash_released <= 1'b0;
        else if (boot_load_done_sync[1]) boot_splash_released <= 1'b1;
    end
end

// A published SDRAM page can exist behind the logo. It is not yet visible.
// Arm on a tutorial SOF actually accepted by the HDMI core, then permit audio
// only at the following blanking VS edge, after that picture frame was sent.
// Reset/relock/no-image cases re-arm this guard; logo/fault screens stay silent.
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) begin
        media_vs_q <= 1'b0;
        media_frame_started <= 1'b0;
        media_audio_ready <= 1'b0;
    end else begin
        media_vs_q <= visual_vs;
        if (!app_rst_n || splash_on || !display_valid_sync[1]) begin
            media_frame_started <= 1'b0;
            media_audio_ready <= 1'b0;
        end else begin
            if (axis_s_valid && axis_s_user && axis_s_ready)
                media_frame_started <= 1'b1;
            if (media_frame_started && (media_vs_q != visual_vs) && !visual_de)
                media_audio_ready <= 1'b1;
        end
    end
end

// TF、SDRAM 与视频时钟配置。
sys_pll sys_pll_m0(
    .refclk     (clk),              // 50 MHz输入
    .clk0_out   (sd_card_clk),      // 100 MHz TF
    .clk1_out   (ext_mem_clk),      // 40 MHz SDRAM
    .clk2_out   (ext_mem_clk_sft),  // 40 MHz 135°，补偿ODDR转发延迟
    .extlock    (sys_lock),         //锁定指示
    .reset      (1'b0)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .clk0_out   (video_clk),        // 25 MHz HDMI视频
    .clk1_out   (hdmi_5x_clk),      // 125 MHz HDMI视频5倍
    .extlock    (video_lock),
    .reset      (1'b0)
);

// Existing PLL actual clock is 12.295082 MHz; shared with internal ADC.
PLL_HDMI_AUDIO u_audio_pll(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (audio_pll_lock),
    .clk0_out   (),
    .clk1_out   (),
    .clk2_out   (audio_mclk)        // 12.295082 MH, 音频 + ADC
);

// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
always @(posedge ext_mem_clk or posedge rst_mem) begin
    if (rst_mem)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

/* ==========================================================================
 * SD 侧跨模块信号：先声明，后使用
 *   sd_card_bmp 的端口直接连到这些网络上，若把声明留在下面的 SD 控制器一节，
 *   Verilog 会先把它们隐式声明成 1 bit wire（TD 报 HDL-7225 CRITICAL-WARNING），
 *   多位总线（sd_bmp_data 8 bit / sd_arb_bmp_addr 32 bit）表面上看不出问题，
 *   但一旦谁改了位宽却漏改这里，就会静默截断而不是报错。所以统一提到使用点之前。
 * ========================================================================== */
wire        sd_init_done;
wire        sd_read_error;
wire        sd_bmp_cancel;

wire        sd_arb_bmp_ready, sd_arb_wav_ready;
wire        sd_arb_bmp_read,  sd_arb_wav_read;
wire [31:0] sd_arb_bmp_addr,  sd_arb_wav_addr;
wire [7:0]  sd_bmp_data,      sd_wav_data;
wire        sd_bmp_valid,     sd_wav_valid;
wire        sd_bmp_end,       sd_wav_end;

// ===================== TF 多图扫描、缩放与四槽全缓存 =====================
sd_card_bmp #(
    .TRAINING_PAGE_INDEX(TRAINING_PAGE_INDEX),
    .CLK_FREQ_HZ       (100_000_000),
    .AUTO_DWELL_S      (AUTO_DWELL_S),
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (3'd4),
    .SCALE_ENABLE      (1'b1),
    .BLUR_BACKGROUND   (BLUR_BACKGROUND),
    .BG_BRIGHTNESS_NUM (BG_BRIGHTNESS_NUM),
    .BG_BRIGHTNESS_SHIFT(BG_BRIGHTNESS_SHIFT),
    // 模糊背景需要完整跑一遍源图取缩略图，超时按两倍源图读取放宽
    .LOAD_TIMEOUT_CYCLES(BLUR_BACKGROUND ? 1_200_000_000 : 300_000_000)
) sd_card_bmp_m0(
    .clk               (sd_card_clk),
    .rst               (rst_sd),
    .key_next          (next_key_n),
    .key_prev          (prev_key_n),
    .key_auto          (1'b1),
    .external_auto     (auto_enable),
    .training_active   (training_enabled),
    // In contact demo KEY2 is a simulated compression, not page navigation.
    .training_next     ((USE_ADC || USE_EXTERNAL_IO) ? app_keys_level[2] : 1'b0),
    .training_prev     ((USE_ADC || USE_EXTERNAL_IO) ? app_keys_level[1] : 1'b0),
    .page_status       (page_status_sd),
    .state_code        (state_code),
    .bmp_width         (16'd640),
    .bmp_height        (16'd480),
    .display_valid     (display_valid),
    .boot_load_done    (boot_load_done_sd),

    .write_finish_toggle(frame_write_toggle_mem),
    .write_buf_idx     (write_buf_idx),
    .disp_buf_idx      (disp_buf_idx),
    .publish_req       (publish_raw),
    .publish_fade      (publish_fade),
    .publish_done      (publish_done),

    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .pixel_ready       (sd_card_pixel_ready),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),

    /* ---- SD 扇区读从接口（与 WAV 共享顶层唯一那份 sd_card_top） ---- */
    .sd_sec_ready          (sd_arb_bmp_ready),
    .sd_sec_read_error     (sd_read_error),
    .sd_init_done          (sd_init_done),
    .sd_sec_read_data      (sd_bmp_data),
    .sd_sec_read_data_valid(sd_bmp_valid),
    .sd_sec_read_end       (sd_bmp_end),
    .sd_sec_read           (sd_arb_bmp_read),
    .sd_sec_read_addr      (sd_arb_bmp_addr),
    .sd_read_cancel        (sd_bmp_cancel)
);

/* ========================================================================== */
/* SD 控制器：顶层唯一一份，BMP 画面与 WAV 音频经仲裁器分时共享                */
/* ========================================================================== */
wire        sd_ready_raw;
wire        sd_read_raw;
wire [31:0] sd_addr_raw;
wire [7:0]  sd_byte_data;
wire        sd_byte_valid;
wire        sd_byte_end;

sd_card_top #(
    .TOKEN_TIMEOUT_CYCLES (10_000_000),   // 100 MHz 下 100 ms
    .SPI_TIMEOUT_CYCLES   ( 1_000_000)    // 100 MHz 下 10 ms
) u_sd_card_top (
    .clk                    (sd_card_clk),
    .rst                    (rst_sd),
    .read_cancel            (sd_bmp_cancel),
    .sd_sec_ready           (sd_ready_raw),
    .sd_sec_read_error      (sd_read_error),
    .SD_nCS                 (sd_ncs),
    .SD_DCLK                (sd_dclk),
    .SD_MOSI                (sd_mosi),
    .SD_MISO                (sd_miso),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (sd_read_raw),
    .sd_sec_read_addr       (sd_addr_raw),
    .sd_sec_read_data       (sd_byte_data),
    .sd_sec_read_data_valid (sd_byte_valid),
    .sd_sec_read_end        (sd_byte_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (8'd0),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

sd_sec_arbiter u_sd_sec_arbiter (
    .clk        (sd_card_clk),
    .rst        (rst_sd),

    .I_sd_ready (sd_ready_raw),
    .O_sd_read  (sd_read_raw),
    .O_sd_addr  (sd_addr_raw),
    .I_sd_data  (sd_byte_data),
    .I_sd_valid (sd_byte_valid),
    .I_sd_end   (sd_byte_end),

    /* ch0：BMP —— 绝对优先，永不丢请求 */
    .O_ch0_ready(sd_arb_bmp_ready),
    .I_ch0_read (sd_arb_bmp_read),
    .I_ch0_addr (sd_arb_bmp_addr),
    .O_ch0_data (sd_bmp_data),
    .O_ch0_valid(sd_bmp_valid),
    .O_ch0_end  (sd_bmp_end),

    /* ch1：WAV —— 请求被吸收，BMP 空闲时补发 */
    .O_ch1_ready(sd_arb_wav_ready),
    .I_ch1_read (sd_arb_wav_read),
    .I_ch1_addr (sd_arb_wav_addr),
    .O_ch1_data (sd_wav_data),
    .O_ch1_valid(sd_wav_valid),
    .O_ch1_end  (sd_wav_end)
);

// state_code 从 sd_card_clk 域同步到 50 MHz 数码管域，再进行译码。
// 逐位同步可能短暂出现中间码，此状态仅作显示，不参与控制。
// 需要一致快照时应改用握手邮箱。
reg [3:0] state_code_meta, state_code_sync;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_code_meta <= 4'd0;
        state_code_sync <= 4'd0;
    end
    else begin
        state_code_meta <= state_code;
        state_code_sync <= state_code_meta;
    end
end

seg_decoder seg_decoder_m0(
    .bin_data          (state_code_sync),
    .seg_data          (seg_data_0)
);

// 左起第 1 位显示当前页号：1..4 为正在显示的浏览页，0 为缺页或读卡失败
// （含尚未出图），5 为按压训练模式。数值取自已经同步到视频域的
// page_status 完整状态字，与页眉显示的是同一份数据。
reg [3:0] page_num;
always @(*) begin
    if (training_enabled)
        page_num = 4'd5;                       // 训练模式
    else if (page_status_video[1] || page_status_video[2])
        page_num = 4'd0;                       // 读卡失败 / 缺页
    else if (page_status_video[11])
        page_num = {2'b00, page_status_video[10:9]} + 4'd1;   // 已显示页 1..4
    else
        page_num = 4'd0;                       // 还没有成功出图
end
// 左起第 1 位显示当前模式：1=教学浏览 2=自动展播 3=按压训练。
// 特殊状态覆盖模式显示，因为此时模式本身已不重要：
//   E = 媒体故障（读卡重试耗尽）  d = 缺页（指定页号不存在）
reg [3:0] mode_num;
always @(*) begin
    if (page_status_video[1])      mode_num = 4'he;   // 媒体故障
    else if (page_status_video[2]) mode_num = 4'hd;   // 缺页
    else                           mode_num = {2'b00, app_mode} + 4'd1;   // 1..3
end
wire [6:0] seg_data_mode;
seg_decoder seg_decoder_mode(
    .bin_data          (mode_num),
    .seg_data          (seg_data_mode)
);

wire [6:0] seg_data_page;
seg_decoder seg_decoder_page(
    .bin_data          (page_num),
    .seg_data          (seg_data_page)
);

// 视频域 LED 状态指示。page_status_video 经跨域同步，可能晚于实际事件。
wire [3:0] led_level = {
    page_status_video[3],                      // LED4: 正在加载 / 恢复 / 等待可用目标
    page_status_video[1] | page_status_video[2],   // LED3: 读卡失败 / 缺页
    media_audio_enable,                         // LED2: 完整教程帧已送出，可播放音频
    training_enabled                           // LED1: 按压训练模式
};
assign led = LED_ACTIVE_LOW ? ~led_level : led_level;

cpr_seg_scan #(.CLK_FREQ(50_000_000)) u_seg_scan(
    .clk               (clk),
    .rst_n             (rst_n),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    .digit0            ({1'b1,seg_data_mode}),   // 左起第 1 位：模式
    .digit1            ({1'b1,7'b011_1111}),     // 左起第 2 位：'-'
    .digit2            ({1'b1,seg_data_page}),   // 左起第 3 位：页号
    .digit3            ({1'b1,7'b1111_111}),     // 左起第 4 位
    .digit4            ({1'b1,7'b1111_111}),     // 左起第 5 位
    .digit5            ({1'b1,7'b1111_111}),     // 左起第 6 位
    .digit6            ({1'b1,7'b1111_111}),     // 左起第 7 位
    .digit7            ({1'b1,seg_data_0})       // 左起第 8 位：SD 加载状态码
);

// ===================== 原图像时序与帧缓存 =====================
video_timing_data video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (rst_video),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0)
);

video_delay video_delay_m0(
    .video_clk         (video_clk),
    .rst               (rst_video),
    .read_en           (video_read_en),
    .read_data         (video_read_data[31:8]),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .hs_r              (hs),
    .vs_r              (vs),
    .de_r              (de),
    .vout_data         (vout_data_raw)
);

// 首图提交前黑屏；提交后一直显示当前显示缓冲区内容
generate if (ENABLE_AUDIO && ENABLE_AUDIO_VISUALIZATION) begin: g_audio_visualization
    cpr_audio_visualizer u_visualizer(
        .clk(video_clk), .rst(rst_video), .enable(1'b1),
        .vs(picture_vs), .de(picture_de), .rgb(app_rgb),
        .sample_valid(audio_output_valid),
        .sample_left(hdmi_audio_left), .sample_right(hdmi_audio_right),
        .out_vs(visual_vs), .out_de(visual_de), .out_rgb(vout_data),
        .level(), .waveform_valid());
end else begin: g_no_audio_visualization
    assign visual_vs=picture_vs;
    assign visual_de=picture_de;
    assign vout_data=app_rgb;
end endgenerate

// 整屏亮度/对比度：吃可视化之后、送 HDMI 之前的最终像素。
// 注意它们在 OSD 之后，所以 OSD 文字（含百分比读数）也会跟着变暗/变灰。
brightness_rgb u_brightness(
    .rgb     (vout_data),
    .level   (brightness_video),
    .out_rgb (adjusted_rgb));
contrast_rgb u_contrast(
    .rgb(adjusted_rgb), .level(contrast_video), .out_rgb(contrasted_rgb));

frame_read_write #(
    // 已验证的缓存写入间距配置。
    .WRITE_BURST_SIZE(128),
    .WRITE_TO_READ_GAP(16),
    .WRITE_RESTART_GAP(64),
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (480),
    .READ_INDEX_SYNCHRONOUS (1)
) frame_read_write_m0(
    .diagnostic_pause (1'b0),
    .mem_clk           (ext_mem_clk),
    .rst               (rst_mem),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),

    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_clk          (video_clk),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .read_finish       (),
    .read_addr_0       (BUF0_ADDR[ADDR_BITS-1:0]),
    .read_addr_1       (BUF1_ADDR[ADDR_BITS-1:0]),
    .read_addr_2       (BUF2_ADDR[ADDR_BITS-1:0]),
    .read_addr_3       (BUF3_ADDR[ADDR_BITS-1:0]),
    .read_addr_index   (active_read_idx),
    .frame_start       (read_frame_start),
    .read_len          (FRAME_PIXELS[ADDR_BITS-1:0]),
    .read_en           (video_read_en),
    .read_data         (video_read_data),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (sd_card_clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_finish      (frame_write_finish),
    .write_ready       (sd_card_pixel_ready),
    .write_addr_0      (BUF0_ADDR[ADDR_BITS-1:0]),
    .write_addr_1      (BUF1_ADDR[ADDR_BITS-1:0]),
    .write_addr_2      (BUF2_ADDR[ADDR_BITS-1:0]),
    .write_addr_3      (BUF3_ADDR[ADDR_BITS-1:0]),
    .write_addr_index  (write_buf_idx),
    .write_len         (FRAME_PIXELS[ADDR_BITS-1:0]),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data)
);

// 将提前返回的读数据对齐到原有 valid 周期。
sdram #(.REGISTER_READ_DATA(1), .FORWARD_CLOCK_ODDR(1)) U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (rst_mem),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// 音频：TF WAV 或片内训练心跳，经 PCM 接口送入 HDMI。
// BMP 与 WAV 共享扇区控制器，BMP 优先；音频 FIFO 仅提供有限缓冲。
// 浏览模式选择当前显示页音轨，自动展播固定选择 FREE_SONG；均单曲循环。
// 训练时选择心跳，WAV 暂停消耗；退出时等待心跳包络收尾再恢复 WAV。
// SW4 每次拨动切换暂停/继续，训练期间忽略；上电前 50 ms 忽略建立过程中的边沿。
// 暂停保留 FIFO 读位置；换曲由 wav_audio_sd_top 内部执行 abort/start。
// heart_en 与自动模式标志在 video_clk 域寄存，再由音频链同步。
// 训练节拍约 110 BPM；BEAT_GATE 默认关闭，beat_hold_ms 仍用于画面节拍指示。
wire        sw4_lvl;

input_filter #(.WIDTH(1), .STABLE_MS(20)) u_wav_sw4 (
    .clk   (video_clk),
    .rst_n (app_rst_n),
    .tick_ms (tick_ms),
    .raw   (dip_sw[3:3]),
    .level (sw4_lvl),
    .rise  ()
);

reg        sw4_lvl_d;
reg  [6:0] wav_init_ms;
reg        wav_play_en;

// 训练模式组合译码先在 video_clk 域寄存，避免毛刺进入音频控制跨域链。
reg        heart_en;
always @(posedge video_clk or negedge app_rst_n) begin
    if (!app_rst_n) heart_en <= 1'b0;
    else            heart_en <= training_enabled && media_audio_enable;
end

wire wav_ctrl_ready;

always @(posedge video_clk or negedge app_rst_n) begin
    if (!app_rst_n) begin
        sw4_lvl_d    <= 1'b0;
        wav_init_ms  <= 7'd0;
        wav_play_en  <= 1'b1;          // 上电默认播放
    end
    else begin
        sw4_lvl_d    <= sw4_lvl;       // 已消抖电平，延迟一拍做边沿检测
        if (tick_ms && (wav_init_ms < 7'd60))
            wav_init_ms <= wav_init_ms + 1'b1;

        // SW4 只切换 WAV 播放使能；训练期间忽略，不影响退出训练后的播放状态。
        if (wav_ctrl_ready && (sw4_lvl ^ sw4_lvl_d) && !heart_en)
            wav_play_en <= ~wav_play_en;
    end
end

assign wav_ctrl_ready = (wav_init_ms >= 7'd50);

wire        wav_ready;
wire        wav_error;
wire [3:0]  wav_error_code;
wire [3:0]  wav_state;

// heart_en 已在 video_clk 域寄存；wav_muted 反映 SW4 暂停状态。
wire        wav_muted = ~wav_play_en | ~media_audio_enable;
// 训练时暂停 WAV 播放，不消耗 FIFO；退出后恢复原读位置。
// PCM 样本为零时仍维持 valid 与 ACR 节奏。
wire        wav_play_gate = wav_play_en & ~heart_en & media_audio_enable;

// 选曲码 0..3 为当前显示页，4 为自动展播的 FREE_SONG。
// 自动展播暂停只停止换页，音轨码仍为 4；进出该模式才触发换曲。
// 自动模式译码先寄存，页号沿用下游的稳定过滤。
reg auto_mode_q;
always @(posedge video_clk or negedge app_rst_n) begin
    if (!app_rst_n) auto_mode_q <= 1'b0;
    else            auto_mode_q <= (app_mode == 2'd1);
end
wire [2:0] audio_sel = auto_mode_q ? 3'd4 : {1'b0, active_read_idx};

wav_audio_sd_top #(
    // 音轨首 LBA 统一定义在 rtl/audio/wav_track_select.v，顶层不覆盖。
    // tools/burn_wav.py 也从该文件读取默认地址。
    .ACR_N        (6144)         // 48 kHz
) u_audio_wav (
    .I_sd_clk        (sd_card_clk),
    .I_mclk          (audio_mclk),
    .I_video_clk     (video_clk),
    .I_sd_rst        (rst_sd),
    .I_mclk_rst      (rst_audio),
    .I_video_rst     (rst_video),

    // 选曲采用帧边界发布后的显示页号；0..3 为页面音轨，4 为 FREE_SONG。
    .I_audio_sel     (audio_sel),

    .I_play          (wav_play_gate),  // SW4 暂停/继续；训练模式强制 0（不读卡，位置保留）
    .I_stop          (1'b0),           // 停止由内部换曲流程产生
    .I_mute          (wav_muted),      // 只有 SW4 暂停（训练屏蔽走 2:1 选择器）
    .I_loop          (1'b1),           // 固定单曲循环
    .I_heart_en      (heart_en),       // 1 = 训练模式：音频口二选一取心跳（已打拍）

    .I_sd_init_done  (sd_init_done),
    .I_sd_sec_ready  (sd_arb_wav_ready),
    .O_sd_sec_addr   (sd_arb_wav_addr),
    .O_sd_sec_read   (sd_arb_wav_read),
    .I_sd_sec_data   (sd_wav_data),
    .I_sd_sec_valid  (sd_wav_valid),
    .I_sd_sec_end    (sd_wav_end),

    .O_audio_valid      (audio_valid),
    .O_audio_left_data  (audio_left_data),
    .O_audio_right_data (audio_right_data),
    .O_acr_valid        (acr_valid),
    .O_acr_cts          (acr_cts),
    .O_acr_n            (acr_n),

    .O_wav_ready      (wav_ready),
    .O_wav_error      (wav_error),
    .O_wav_error_code (wav_error_code),
    .O_wav_state      (wav_state),
    .O_file_size      (),
    .O_sample_rate    (),
    .O_channels       (),
    .O_bits           (),
    .O_frame_total    (),
    .O_play_pos       (),
    .O_play_end       (),
    .O_buf_level      (),
    .O_underrun       ()
);

// ===================== RGB/DE 转 AXIS 视频 =====================
// LOGO 在送入 AXIS 前覆盖最终像素，不受转场和 OSD 影响。
// 预载、首帧发布及最短展示条件满足后，在场消隐交棒。
wire [23:0] splash_rgb;
splash_boot u_splash (
    .clk   (video_clk),
    .rst   (rst_video),
    .vs    (visual_vs),
    .de    (visual_de),
    .hide  (boot_splash_released),
    .rgb   (splash_rgb),
    .active(splash_on)
);

video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_video),
    .I_vs          (visual_vs),
    .I_de          (visual_de),
    .I_rgb         (splash_on ? splash_rgb : contrasted_rgb),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (rst_video),
    .O_pulse (edid_trig)
);

// ===================== 带音频的 HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 800        ),
    .HSA                    ( 96         ),
    .HFP                    ( 16         ),
    .HBP                    ( 48         ),
    .HACTIVE                ( 640        ),
    .VTOTAL                 ( 525        ),
    .VSA                    ( 2          ),
    .VFP                    ( 10         ),
    .VBP                    ( 33         ),
    .VACTIVE                ( 480        ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_video),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_output_valid),
    .I_audio_left_data  (hdmi_audio_left),
    .I_audio_right_data (hdmi_audio_right),
    .I_acr_valid        (acr_output_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_video),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule
