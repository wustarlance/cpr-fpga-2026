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
    // 阈值放宽（2026-10-28 第三轮，板上实测峰值 1783 后重定）：
    //   探针实测：5~6cm 按压的锁存峰值只有 1783（不是按码值推算的 2050~2150）。
    //   对比 2cm 的峰值约 1550 —— 两者只差 230 码，说明 FSR(20kg 档) 在 5~18kg
    //   这一段已经进入饱和平台区，靠电阻变化分不出"浅"和"深"。
    //   既然硬件分不出来，就把目标带放宽到 1200~2400（1200 码），宁可与人为善：
    //       轻碰(<1200) 浅 ｜ 1~6cm(1200~2400) 目标 ｜ 狠砸(>2400) 深
    //   这样现场只要"认真往下压"就能拿到目标档，不会因为压在 1750 边界上来回跳。
    top #(.USE_ADC(1), .USE_EXTERNAL_IO(USE_EXTERNAL_IO),
          .RELEASE_BASELINE(12'd2900), .TRIGGER_LEVEL(12'd250),
          .RELEASE_LEVEL(12'd120),     .TARGET_LOW(12'd1200),
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
