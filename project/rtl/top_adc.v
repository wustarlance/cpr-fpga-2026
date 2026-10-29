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
    // 2026-10-28 按压盒实测标定（CH4 / J2-35 / 3.3k + FSR，四根弹簧 60mm 共 15~18kg）：
    //   空载 2900（上电后 1~2 分钟稳定值，自身会缓慢下漂 30~40 码/30s）
    //   2cm 1300~1400 → 峰值 1500~1600
    //   5cm  750~850  → 峰值 2050~2150
    //   6cm  <700      → 峰值 2200+
    // 阈值放宽（2026-10-28 第四轮，收回到"稍微放宽"）：
    //   第三轮把目标带放到 1200~2400，结果轻碰一下也判 2 —— 反馈失去意义。
    //   现按板上两个实测锚点重新卡位（峰值都会被压在 1500~1800 这段窄区里）：
    //       2cm 峰值 ≈1550 → 必须算"浅"
    //       5~6cm 峰值 1783 → 必须算"目标"
    //   取 TARGET_LOW=1600：比实测峰值低 183 码（留足波动余量），
    //   又比 2cm 的 1550 高 50 码（2cm 及以下稳定判"浅"）。
    //   上界 2400：正常压到底也够不到，只有狠砸才进"深"。
    //   净效果：1600~2400 共 800 码，比第一版的 1900~2220(320 码) 宽 2.5 倍，
    //   但"轻了仍是浅"，不像 1200 那样什么按压都给目标。
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
