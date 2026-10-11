// Internal ADC variant of the same board top. All board pin names are shared.
// Defaults are test pressure codes, not calibrated physical depth thresholds.
module top_adc (
    input wire clk, rst_n, key1, key3, key2,
    input wire [3:0] dip_sw,
    input wire [4:0] ext_keys_n,
    input wire [3:0] depth_sw_n,
    output wire [5:0] seg_sel,
    output wire [7:0] seg_data,
    output wire HDMI_CLK_P, HDMI_D2_P, HDMI_D1_P, HDMI_D0_P,
    output wire HDMI_DDC_SCL,
    inout wire HDMI_DDC_SDA,
    output wire sd_ncs, sd_dclk, sd_mosi,
    input wire sd_miso
);
    top #(.USE_ADC(1)) u_board (
        .clk          (clk),
        .rst_n        (rst_n),
        .key1         (key1),
        .key3         (key3),
        .key2         (key2),
        .dip_sw       (dip_sw),
        .ext_keys_n   (ext_keys_n),
        .depth_sw_n   (depth_sw_n),
        .seg_sel      (seg_sel),
        .seg_data     (seg_data),
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
