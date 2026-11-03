// Internal ADC variant of the same board top. All board pin names are shared.
// Defaults are test pressure codes, not calibrated physical depth thresholds.
module top_adc #(parameter USE_EXTERNAL_IO=1,
                 parameter ENABLE_AUDIO=1,
                 parameter ENABLE_AUDIO_VISUALIZATION=1,
                 parameter ENABLE_SMOOTH_TRANSITIONS=1,
                 parameter BLUR_BACKGROUND=1,
                 parameter integer BG_BRIGHTNESS_NUM=3,
                 parameter integer BG_BRIGHTNESS_SHIFT=2,
                 parameter UI_LANGUAGE_ZH=1,
                 parameter LED_ACTIVE_LOW=0,
                 parameter [1:0] TRAINING_PAGE_INDEX=2'd1)(
    input wire clk, rst_n, key1, key3, key2,
    input wire [3:0] dip_sw,
    input wire [4:0] ext_keys_n,
    input wire [6:0] key_panel_n,   // 外接八位按键面板 K1~K7（K7 = 字幕开关）
    input wire [3:0] depth_sw_n,
    output wire [7:0] seg_sel,
    output wire [7:0] seg_data,
    output wire [3:0] led,
    output wire HDMI_CLK_P, HDMI_D2_P, HDMI_D1_P, HDMI_D0_P,
    output wire HDMI_DDC_SCL,
    inout wire HDMI_DDC_SDA,
    output wire sd_ncs, sd_dclk, sd_mosi,
    input wire sd_miso
);
    // 按压盒联调参数：CH4 / J2-35，3.3 kΩ + FSR。
    // 空载参考约 2900，存在温漂；两次峰值记录约 1550 与 1783，用于确定目标带下界 1600。
    // 1600~2400 为压力幅度分级，尚不能作为毫米或厘米位移标定。
    top #(.USE_ADC(1), .USE_EXTERNAL_IO(USE_EXTERNAL_IO),
          .RELEASE_BASELINE(12'd2900), .TRIGGER_LEVEL(12'd250),
          .RELEASE_LEVEL(12'd120),     .TARGET_LOW(12'd1600),
          .TARGET_HIGH(12'd2400),
          .ENABLE_AUDIO(ENABLE_AUDIO), .LED_ACTIVE_LOW(LED_ACTIVE_LOW),
          .ENABLE_AUDIO_VISUALIZATION(ENABLE_AUDIO_VISUALIZATION),
          .ENABLE_SMOOTH_TRANSITIONS(ENABLE_SMOOTH_TRANSITIONS),
          .BLUR_BACKGROUND(BLUR_BACKGROUND),
          .BG_BRIGHTNESS_NUM(BG_BRIGHTNESS_NUM),
          .BG_BRIGHTNESS_SHIFT(BG_BRIGHTNESS_SHIFT),
          .TRAINING_PAGE_INDEX(TRAINING_PAGE_INDEX), .UI_LANGUAGE_ZH(UI_LANGUAGE_ZH)) u_board (
        .clk          (clk),
        .rst_n        (rst_n),
        .key1         (key1),
        .key3         (key3),
        .key2         (key2),
        .dip_sw       (dip_sw),
        .ext_keys_n   (ext_keys_n),
        .key_panel_n  (key_panel_n),
        .depth_sw_n   (depth_sw_n),
        .seg_sel      (seg_sel),
        .seg_data     (seg_data),
        .led          (led),
        .HDMI_CLK_P   (HDMI_CLK_P),
        .HDMI_D2_P    (HDMI_D2_P),
        .HDMI_D1_P    (HDMI_D1_P),
        .HDMI_D0_P    (HDMI_D0_P),
        .HDMI_DDC_SCL (HDMI_DDC_SCL),
        .HDMI_DDC_SDA (HDMI_DDC_SDA),
        .sd_ncs       (sd_ncs),
        .sd_dclk      (sd_dclk),
        .sd_mosi      (sd_mosi),
        .sd_miso      (sd_miso)
    );
endmodule
