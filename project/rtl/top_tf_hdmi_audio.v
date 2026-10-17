
// Default top is the board-button demo. top_adc selects the internal ADC path.
module top #(
    parameter USE_EXTERNAL_IO = 0,
    parameter USE_ADC = 0,
    parameter UI_LANGUAGE_ZH = 1,
    parameter [1:0] TRAINING_PAGE_INDEX = 2'd1,
    parameter [11:0] RELEASE_BASELINE = 12'd3000,
    parameter [11:0] TRIGGER_LEVEL = 12'd150,
    parameter [11:0] RELEASE_LEVEL = 12'd100,
    parameter [11:0] TARGET_LOW = 12'd800,
    parameter [11:0] TARGET_HIGH = 12'd1600
)(
    input                       clk,
    input                       rst_n,
    input                       key1,           // 手动下一张
    input                       key3,           // KEY3 (B1), previous
    input wire [3:0]             dip_sw,         // SW1..4, active high; DEMO ONLY
    input wire [4:0]             ext_keys_n,     // mode/prev/next/brightness/session clear
    input wire [3:0]             depth_sw_n,     // cumulative contacts, close to GND
    input                       key2,           // KEY4 (C1), mode

    output [5:0]                seg_sel,
    output [7:0]                seg_data,

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
wire [23:0] audio_left_data;
wire [23:0] audio_right_data;
wire        acr_valid;
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
wire [4:0] app_keys_raw = USE_EXTERNAL_IO ? ~ext_keys_n : {2'b00,~key1,~key3,~key2};
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
    .raw_switches(dip_sw[2:0]), .training_enabled(training_enabled),
    .contrast_level(contrast_level));
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) contrast_video <= 3'd2;
    else if (brightness_vs_d && !vs) contrast_video <= contrast_level;
end
wire [23:0] app_rgb, adjusted_rgb, contrasted_rgb;
brightness_rgb u_brightness(
    .rgb(display_valid_sync[1] ? vout_data_raw : 24'h102030),
    .level   (brightness_video),
    .out_rgb (adjusted_rgb));
contrast_rgb u_contrast(
    .rgb(adjusted_rgb), .level(contrast_video), .out_rgb(contrasted_rgb));
cpr_overlay #(.UNCALIBRATED_PRESSURE(USE_ADC), .PAGE_STATUS_ENABLE(1),
              .CHINESE_UI(UI_LANGUAGE_ZH)) u_overlay(
    .clk (video_clk),
    .rst (rst_video),
    .vs  (vs),
    .de  (de),
    .rgb(contrasted_rgb),
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

// ===================== TF 多图扫描、缩放与四槽全缓存 =====================
sd_card_bmp #(
    .TRAINING_PAGE_INDEX(TRAINING_PAGE_INDEX),
    .CLK_FREQ_HZ       (100_000_000),
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (3'd4),
    .SCALE_ENABLE      (1'b1)
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
    .publish_req       (publish_req),
    .publish_done      (publish_done),

    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .pixel_ready       (sd_card_pixel_ready),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .SD_nCS            (sd_ncs),
    .SD_DCLK           (sd_dclk),
    .SD_MOSI           (sd_mosi),
    .SD_MISO           (sd_miso)
);

seg_decoder seg_decoder_m0(
    .bin_data          (state_code),
    .seg_data          (seg_data_0)
);

seg_scan seg_scan_m0(
    .clk               (clk),
    .rst_n             (rst_n),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    .seg_data_0        ({1'b1,7'b1111_111}),
    .seg_data_1        ({1'b1,7'b1111_111}),
    .seg_data_2        ({1'b1,7'b1111_111}),
    .seg_data_3        ({1'b1,7'b1111_111}),
    .seg_data_4        ({1'b1,7'b1111_111}),
    .seg_data_5        ({1'b1,seg_data_0})
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
assign vout_data = app_rgb; // status UI is visible while SD scans or is absent

frame_read_write #(
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (480),
    .READ_INDEX_SYNCHRONOUS (1)
) frame_read_write_m0(
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

sdram U3(
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

// ===================== 音频：内部 I2S 音源 =====================
// 教学/展播模式播放 do-re-mi 音阶作为背景音；按压训练模式锁定 A4 440 Hz，
// 使每一次按压提示音的音高一致。修复前节拍音会跟随音阶漂移，同一组按压
// 每拍的音高都不同，听感上不成立为节拍器。
cpr_audio_tone_i2s #(
    .AMP              (24'sd2000000),
    .NOTE_HOLD_FRAMES (24000),        // 0.5 s / 音符 @ 48 kHz
    .METRONOME_NOTE   (3'd5)          // la / A4 440 Hz
) u_cpr_audio_tone (
    .I_mclk      (audio_mclk),
    .I_rst       (rst_audio),
    .I_metronome (app_mode == 2'd2),
    .O_i2s_BCLK  (audio_i2s_bclk),
    .O_i2s_LRCK  (audio_i2s_lrck),
    .O_i2s_DOUT  (audio_i2s_dout)
);

I2S_receiver u_I2S_receiver(
    .I_clk              (video_clk),
    .I_rst              (rst_video),
    .I_i2s_BCLK         (audio_i2s_bclk),
    .I_i2s_LRCK         (audio_i2s_lrck),
    .I_i2s_DOUT         (audio_i2s_dout),
    .O_audio_valid      (audio_valid),
    .O_audio_left_data  (audio_left_data),
    .O_audio_right_data (audio_right_data)
);

audio_arc_calculate #(
    .ACR_N         (6144)
) u_audio_arc_calculate (
    .I_clk         (video_clk),
    .I_rst         (rst_video),
    .I_audio_valid (audio_valid),
    .O_acr_valid   (acr_valid),
    .O_acr_cts     (acr_cts),
    .O_acr_n       (acr_n)
);

// ===================== RGB/DE 转 AXIS 视频 =====================
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_video),
    .I_vs          (vs),
    .I_de          (de),
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

    .I_audio_valid      (audio_valid),
    .I_audio_left_data  (audio_gate ? audio_left_data : 24'd0),
    .I_audio_right_data (audio_gate ? audio_right_data : 24'd0),
    .I_acr_valid        (acr_valid),
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
