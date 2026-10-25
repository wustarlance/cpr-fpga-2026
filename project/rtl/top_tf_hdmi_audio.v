
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
    parameter UI_LANGUAGE_ZH = 1,
    parameter [1:0] TRAINING_PAGE_INDEX = 2'd1,
    parameter [11:0] RELEASE_BASELINE = 12'd3000,
    parameter [11:0] TRIGGER_LEVEL = 12'd150,
    parameter [11:0] RELEASE_LEVEL = 12'd100,
    parameter [11:0] TARGET_LOW = 12'd800,
    parameter [11:0] TARGET_HIGH = 12'd1600,
    // 板载 4 个独立 LED 只作调试指示。实测为高电平点亮：上板时驱动值全取反后
    // 四个灯全亮，说明引脚为 1 时点亮。这一条与数码管（共阳、低电平点亮）相反，
    // 不要按数码管的极性类推。
    parameter LED_ACTIVE_LOW = 0
)(
    input                       clk,
    input                       rst_n,
    input                       key1,           // 手动下一张
    input                       key3,           // KEY3 (B1), previous
    input wire [3:0]             dip_sw,         // SW1..4, active high; DEMO ONLY
    input wire [4:0]             ext_keys_n,     // mode/prev/next/brightness/session clear
    // 外接八位按键面板（J1 奇数行 13~23）。模块自带上拉，按下为低电平。
    // K1~K5 与板载 KEY 并存；K6 留给对比度按键；K7/K8 暂未使用。
    input wire [5:0]             key_panel_n,
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
wire rst_video = ~app_rst_n;
wire rst_sd = ~sd_rst_n;
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
wire [4:0] app_keys_level;
wire [11:0] page_status_sd, page_status_video;
page_status_cdc u_page_status(
    .src_clk(sd_card_clk), .src_rst_n(sd_rst_n), .status(page_status_sd),
    .dst_clk(video_clk), .dst_rst_n(app_rst_n), .video_status(page_status_video));
// 三条来源并存：板载 KEY、扩展口 ext_keys_n、外接八位面板。
// 全部先反相成高有效，再按位相或——任何一处的按键都能操作，互不屏蔽。
//
// 板载 KEY 不再受 USE_EXTERNAL_IO 屏蔽：原实现 USE_EXTERNAL_IO=1 时直接丢弃
// 板载键，接了外接控制盒就按不动板载键了。现在两者始终并存。
// 已量产的按压盒仍可用板载 KEY2/KEY3/KEY4 临时操作，KEY1 始终是复位。
wire [4:0] onboard_keys = {2'b00, ~key1, ~key3, ~key2};
wire [4:0] panel_keys   = ~key_panel_n[4:0];
wire [4:0] app_keys_raw;
key_source_merge u_key_merge(
    .onboard_keys (onboard_keys),
    .panel_keys   ((USE_EXTERNAL_IO ? ~ext_keys_n : 5'b00000) | panel_keys),
    .keys         (app_keys_raw));
// Board demo: KEY2 generates a press; dips select a contact pattern, zero selects target.
// External mode observes real contacts directly; calibration remains a mechanical task.
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
    .clear_session       (clear_session));

// ADC 路径：generate 是【综合期二选一】，不是运行时的 if。
// USE_ADC=0 时整条采样链不会被综合进去（top 比 top_adc 少约 250 LUT）。
generate
    if (USE_ADC) begin : g_adc
        wire adc_soc, adc_pd, adc_eoc;
        wire [2:0] adc_channel;
        wire [11:0] adc_dout;
        // EG_PHY_ADC 是 FPGA 硬核原语，直接接管专用 ADC pad：
        //   CH1("ENABLE")  → 通道 1 = M10，经 RN23 到 J1 第 16 脚
        //   VREF("ENABLE") → 内部参考电压，在独立的 L11 pad 上
        // 因为走专用 pad，pin.adc 里【找不到 M10/L11】的 set_pin_assignment。
        // 时钟复用音频 PLL 的 12.295082 MHz —— 音频本来就要跑，不多占 PLL（器件共 4 个）。
        // TN304: CH1 is M10 -> RN23 -> J1 pin 16. No digital top port is
        // assigned to this multiplexed pad. Enable VREF (BG256 L11) per
        // TN304's parameter contract. Its actual board voltage and the
        // front-end range require bench checking before analog use.
        EG_PHY_ADC #(.CH1("ENABLE"), .VREF("ENABLE")) u_adc (
            .clk  (audio_mclk),
            .pd   (adc_pd),
            .s    (adc_channel),
            .soc  (adc_soc),
            .eoc  (adc_eoc),
            .dout (adc_dout));
        cpr_sensor_path #(
            .ADC_CLK_HZ       (12295082),
            .SAMPLE_HZ        (200000),
            .CHANNEL          (1),
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
wire audio_gate = (app_mode != 2) || (beat_hold_ms != 0);
// Share the final gated PCM words between HDMI and its on-screen monitor.
wire [23:0] hdmi_audio_left = (ENABLE_AUDIO && audio_gate) ? audio_left_data : 24'd0;
wire [23:0] hdmi_audio_right = (ENABLE_AUDIO && audio_gate) ? audio_right_data : 24'd0;
assign audio_output_valid = ENABLE_AUDIO ? audio_valid : 1'b0;
assign acr_output_valid = ENABLE_AUDIO ? acr_valid : 1'b0;
reg [1:0] display_valid_sync;
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
contrast_controls #(.HOLD_DURING_TRAINING(!(USE_ADC || USE_EXTERNAL_IO))) u_contrast_controls(
    .clk(video_clk), .rst_n(app_rst_n), .tick_ms(tick_ms),
    .raw_switches(dip_sw[2:0]),
    .raw_key     (~key_panel_n[5]),          // K6：对比度，按下为低电平
    .training_enabled(training_enabled),
    .contrast_level(contrast_level));
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) contrast_video <= 3'd2;
    else if (brightness_vs_d && !vs) contrast_video <= contrast_level;
end
wire [23:0] app_rgb, adjusted_rgb, contrasted_rgb, picture_rgb;
wire picture_vs, picture_de;
brightness_rgb u_brightness(
    .rgb(display_valid_sync[1] ? vout_data_raw : 24'h102030),
    .level   (brightness_video),
    .out_rgb (adjusted_rgb));
contrast_rgb u_contrast(
    .rgb(adjusted_rgb), .level(contrast_video), .out_rgb(contrasted_rgb));
generate if (ENABLE_SMOOTH_TRANSITIONS) begin: g_slide_fade
    cpr_slide_fade u_fade(
        .clk(video_clk), .rst(rst_video), .request_async(fade_request),
        .vs(vs), .de(de), .rgb(contrasted_rgb),
        .ready(fade_ready), .out_vs(picture_vs), .out_de(picture_de),
        .out_rgb(picture_rgb), .gain());
end else begin: g_no_slide_fade
    assign picture_rgb=contrasted_rgb;
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
    .pause_warning       (pause_warning),
    .rotate_due          (rotate_due),
    .beat                (beat_hold_ms != 0),
    .out_rgb             (app_rgb));
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) display_valid_sync <= 0;
    else display_valid_sync <= {display_valid_sync[0],display_valid};
end

// 保持你原来的 TF / SDRAM / video 时钟
sys_pll sys_pll_m0(
    .refclk     (clk),              // 50 MHz输入
    .clk0_out   (sd_card_clk),      // 100 MHz TF
    .clk1_out   (ext_mem_clk),      // 40 MHz SDRAM
    .clk2_out   (ext_mem_clk_sft),  // 40 MHz 180° SDRAM相位
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

seg_decoder seg_decoder_m0(
    .bin_data          (state_code),
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

// 4 个板载 LED 之前完全没接，上电停在默认状态，测点信息看不到。这里把它们
// 接成视频域的调试指示，切图/进训练/出错时不用低头看数码管。
// 注意 page_status_video 是跨时钟域同步来的状态，比实际显示可能晚一两帧。
wire [3:0] led_level = {
    page_status_video[3],                      // LED4: 正在加载 / 恢复 / 等待可用目标
    page_status_video[1] | page_status_video[2],   // LED3: 读卡失败 / 缺页
    display_valid_sync[1],                     // LED2: 有图在显示
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
wire visual_vs, visual_de;
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

frame_read_write #(
    // D123 exploratory real-image verification: D122-backed writer cadence.
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

// D110-backed opt-in: align early read data to the unchanged valid cycle.
sdram #(.REGISTER_READ_DATA(1)) U3(
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

// ===================== 音频：SD 卡 WAV 播放 → HDMI 数据岛 =====================
// 变更说明（2026-10-24）：
//   原先是内部 do-re-mi 音调发生器 → I2S 三线 → I2S_receiver 解码 → HDMI 核。
//   现改为直接播 SD 卡里的 WAV 文件：PCM 24bit 直连 HDMI 核的音频口，
//   ACR（N/CTS）包由本模块内部按 48 kHz 生成，因此
//   I2S_receiver 与 audio_arc_calculate 两级全部省去。
//
// SD 卡与 BMP 共用顶层唯一那份 sd_card_top，经 sd_sec_arbiter 分时仲裁：
//   BMP 优先（画面不能花），WAV 让路（FIFO 约 21 ms 缓冲，切页瞬间可能欠载）。
//
// 播放控制（2026-10-24 新增 SW4）：
//   SW1 (C8, dip_sw[0]) = 循环播放，1 = 单文件循环
//   SW4 (C5, dip_sw[3]) = 播放 / 停止开关：**拨动一次切换一次**
//   SW2/SW3 已被对比度（contrast_controls）占用，不做播放控制。
//
// 为什么用"拨动切换"而不是"拨上=停、拨下=播"：
//   板卡 DEMO（2_Example/.../8_key_sw/key_sw.adc）把 C8/C7/C6/C5 这四位拨码和
//   A2/B2/B1/C1 四个按键接在同一组带上拉的输入里，注释写 "when the keydown,
//   the value is 0"，即闭合 = 低。但拨码"拨上"到底是闭合还是断开，资料里没有
//   唯一结论（本工程旧注释写 active high，与上拉电路矛盾）。若按固定极性判，
//   极性一旦判反，上电就是静音。改成边沿切换后，开关停在哪个位置都不影响
//   上电播放，两种极性都能用。
//
// 上电 50 ms 内不响应拨动：input_filter 要 20 ms 才稳定，这段时间的边沿是
// 上电建立过程，必须忽略，否则开关停在某个位置会在开机瞬间把状态翻掉。
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

wire wav_ctrl_ready;

always @(posedge video_clk or negedge app_rst_n) begin
    if (!app_rst_n) begin
        sw4_lvl_d   <= 1'b0;
        wav_init_ms <= 7'd0;
        wav_play_en <= 1'b1;              // 上电默认播放
    end
    else begin
        sw4_lvl_d <= sw4_lvl;             // 已消抖电平，延迟一拍做边沿检测
        if (tick_ms && (wav_init_ms < 7'd60))
            wav_init_ms <= wav_init_ms + 1'b1;
        // 拨动一次切换一次；上电 50 ms 内的边沿属于建立过程，被 ready 挡掉
        if (wav_ctrl_ready && (sw4_lvl ^ sw4_lvl_d))
            wav_play_en <= ~wav_play_en;
    end
end

assign wav_ctrl_ready = (wav_init_ms >= 7'd50);
wire wav_sw4_edge = wav_ctrl_ready && (sw4_lvl ^ sw4_lvl_d);

wire        wav_ready;
wire        wav_error;
wire [3:0]  wav_error_code;
wire [3:0]  wav_state;

wav_audio_sd_top #(
    .START_SECTOR (32'd12000),   // WAV 首扇区，必须与烧卡工具 --lba 一致
    .ACR_N        (6144)         // 48 kHz
) u_audio_wav (
    .I_sd_clk        (sd_card_clk),
    .I_mclk          (audio_mclk),
    .I_video_clk     (video_clk),
    .I_sd_rst        (rst_sd),
    .I_mclk_rst      (rst_audio),
    .I_video_rst     (rst_video),

    .I_play          (wav_play_en),    // SW4 拨动一次切换；上电 = 播放
    .I_stop          (wav_sw4_edge),   // 每次拨动回到文件开头（单拍）
    .I_mute          (~wav_play_en),   // 停止时静音（帧节拍照常走，HDMI 流不断）
    .I_loop          (dip_sw[0]),      // SW1 = 循环

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
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_video),
    .I_vs          (visual_vs),
    .I_de          (visual_de),
    .I_rgb         (vout_data),
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
