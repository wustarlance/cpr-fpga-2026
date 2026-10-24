`timescale 1ns/1ps
// Independent board diagnostic. The product top, clocks and pin map are unchanged.
module top_sdram_diag(
    input wire clk, rst_n, key1, key3, key2,
    input wire [3:0] dip_sw,
    input wire [4:0] ext_keys_n,
    input wire [3:0] depth_sw_n,
    output wire [7:0] seg_sel, seg_data,
    output wire [3:0] led,
    output wire HDMI_CLK_P, HDMI_D2_P, HDMI_D1_P, HDMI_D0_P,
    output wire HDMI_DDC_SCL,
    inout wire HDMI_DDC_SDA,
    output wire sd_ncs, sd_dclk, sd_mosi,
    input wire sd_miso
);
    wire sd_card_clk, ext_mem_clk, ext_mem_clk_sft, video_clk, hdmi_5x_clk;
    wire sys_lock, video_lock;
    sys_pll sys_pll_m0(.refclk(clk), .reset(1'b0), .extlock(sys_lock),
        .clk0_out(sd_card_clk), .clk1_out(ext_mem_clk), .clk2_out(ext_mem_clk_sft));
    video_pll video_pll_m0(.refclk(clk), .reset(1'b0), .extlock(video_lock),
        .clk0_out(video_clk), .clk1_out(hdmi_5x_clk));
    wire reset_async_n = rst_n && sys_lock && video_lock;
    wire mem_rst_n, video_rst_n;
    reset_release u_mem_reset(.clk(ext_mem_clk), .reset_n_async(reset_async_n),
        .ready(1'b1), .rst_n(mem_rst_n));
    reset_release u_video_reset(.clk(video_clk), .reset_n_async(reset_async_n),
        .ready(1'b1), .rst_n(video_rst_n));

    // No TF commands, no card writes. No frame FIFO is instantiated here.
    assign sd_ncs = 1'b1;
    assign sd_dclk = 1'b0;
    assign sd_mosi = 1'b1;
    reg [3:0] dip_meta, dip_sync;
    always @(posedge ext_mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin dip_meta <= 0; dip_sync <= 0; end
        else begin dip_meta <= dip_sw; dip_sync <= dip_meta; end
    end
    wire init_done, refresh_active, unused_busy, wr_en, rd_en, rd_valid;
    wire [20:0] wr_addr, rd_addr, first_bad_addr, last_bad_addr;
    wire [31:0] wr_data, rd_data, expected_data, actual_data;
    wire [31:0] head_map, mismatch_count, mismatch_count_2;
    wire [3:0] status;
    wire [1:0] phase, fault;
    wire done;
    sdram_bist u_bist(.clk(ext_mem_clk), .rst(!mem_rst_n),
        .init_done(init_done), .refresh_active(refresh_active), .short_burst(dip_sync[0]),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_en(rd_en), .rd_addr(rd_addr), .rd_valid(rd_valid), .rd_data(rd_data),
        .status(status), .phase(phase), .first_bad_addr(first_bad_addr),
        .first_expected(expected_data), .first_actual(actual_data), .done(done), .fault(fault),
        .head_map(head_map), .mismatch_count(mismatch_count),
        .mismatch_count_2(mismatch_count_2), .last_bad_addr(last_bad_addr));
    sdram U3(.Clk(ext_mem_clk), .Clk_sft(ext_mem_clk_sft), .Rst(!mem_rst_n),
        .Sdr_init_done(init_done), .Sdr_init_ref_vld(refresh_active), .Sdr_busy(unused_busy),
        .App_wr_en(wr_en), .App_wr_addr(wr_addr), .App_wr_din(wr_data), .App_wr_dm(4'b0000),
        .App_rd_en(rd_en), .App_rd_addr(rd_addr), .Sdr_rd_en(rd_valid), .Sdr_rd_dout(rd_data));
    assign led = {done && status != 4, done && status == 4, init_done && !done, init_done};

    // All multi-bit result data stays in the memory clock domain, including scan.
    // SW2 selects a page set; SW4/SW3 select the page inside it.
    reg [31:0] display_word;
    always @(*) begin
        if (!dip_sync[1]) begin
            case (dip_sync[3:2])
                0: display_word = {16'hd107, status, 2'b00, phase, 2'b00, fault, 4'b0000};
                1: display_word = {11'd0, first_bad_addr};
                2: display_word = expected_data;
                3: display_word = actual_data;
            endcase
        end else begin
            case (dip_sync[3:2])
                0: display_word = head_map;
                1: display_word = mismatch_count;
                2: display_word = mismatch_count_2;
                3: display_word = {11'd0, last_bad_addr};
            endcase
        end
    end
    wire [63:0] digits;
    genvar n;
    generate for (n=0; n<8; n=n+1) begin : g_digits
        seg_decoder u_hex(.bin_data(display_word[31-n*4 -: 4]),
            .seg_data(digits[62-n*8 -: 7]));
        assign digits[63-n*8] = 1'b1;
    end endgenerate
    cpr_seg_scan #(.CLK_FREQ(40000000)) u_seg_scan(.clk(ext_mem_clk), .rst_n(mem_rst_n),
        .seg_sel(seg_sel), .seg_data(seg_data),
        .digit0(digits[63:56]), .digit1(digits[55:48]), .digit2(digits[47:40]),
        .digit3(digits[39:32]), .digit4(digits[31:24]), .digit5(digits[23:16]),
        .digit6(digits[15:8]), .digit7(digits[7:0]));

    // Only persistent terminal flags cross to video. No incoherent result bus.
    reg pass_meta, pass_sync, fail_meta, fail_sync;
    always @(posedge video_clk or negedge video_rst_n) begin
        if (!video_rst_n) begin pass_meta<=0; pass_sync<=0; fail_meta<=0; fail_sync<=0; end
        else begin
            pass_meta <= done && status == 4; pass_sync <= pass_meta;
            fail_meta <= done && status != 4; fail_sync <= fail_meta;
        end
    end
    wire hs, vs, de;
    wire [7:0] r, g, b;
    color_bar u_pattern(.clk(video_clk), .rst(!video_rst_n), .hs(hs), .vs(vs), .de(de),
        .rgb_r(r), .rgb_g(g), .rgb_b(b));
    // Color bars are generated directly from video timing, never SDRAM readback.
    // Blue while running; green success tint; red failure tint. No horizontal lines.
    wire [23:0] rgb = fail_sync ? {r|8'h80, g>>2, b>>2} :
                         pass_sync ? {r>>2, g|8'h80, b>>2} : {r>>2, g>>2, b|8'h80};
    wire axis_user, axis_valid, axis_last, axis_ready;
    wire [23:0] axis_data;
    video_rgb_to_axis_640x480 u_axis(.I_clk(video_clk), .I_rst(!video_rst_n),
        .I_vs(vs), .I_de(de), .I_rgb(rgb), .O_video_user(axis_user),
        .O_video_valid(axis_valid), .O_video_last(axis_last), .O_video_data(axis_data));
    wire edid_trig;
    startup_pulse #(.CNT_MAX(20'd100000)) u_startup(.I_clk(video_clk),
        .I_rst(!video_rst_n), .O_pulse(edid_trig));
    wire [9:0] ch0, ch1, ch2, chclk;
    hdmi_1_4b_transmitter_core_wrapper #(
        .DEVICE("EG"), .HTOTAL(800), .HSA(96), .HFP(16), .HBP(48), .HACTIVE(640),
        .VTOTAL(525), .VSA(2), .VFP(10), .VBP(33), .VACTIVE(480), .VIDEO_VIC(1),
        .VIDEO_TPG("Disable"), .VIDEO_FORMAT("RGB"), .AUDIO_SAMPLE_RATE("48K"), .IIC_SCL_DIV(250)
    ) u_hdmi(.I_pixel_clk(video_clk), .I_rst(!video_rst_n), .I_edid_read_trig(edid_trig),
        .O_edid_read_valid(), .O_edid_read_data(), .I_axis_s_user(axis_user),
        .I_axis_s_valid(axis_valid), .I_axis_s_last(axis_last), .I_axis_s_data(axis_data),
        .O_axis_s_ready(axis_ready), .I_audio_valid(1'b0), .I_audio_left_data(24'd0),
        .I_audio_right_data(24'd0), .I_acr_valid(1'b0), .I_acr_cts(20'd0), .I_acr_n(20'd0),
        .O_video_locked(), .O_ddc_scl(HDMI_DDC_SCL), .IO_ddc_sda(HDMI_DDC_SDA),
        .O_ch0_tmds_data(ch0), .O_ch1_tmds_data(ch1), .O_ch2_tmds_data(ch2), .O_clk_tmds_data(chclk));
    hdmi_phy_wrapper #(.DEVICE("EG")) u_phy(.I_pixel_clk(video_clk),
        .I_serial_clk(hdmi_5x_clk), .I_rst(!video_rst_n),
        .I_tmds_channel_0(ch0), .I_tmds_channel_1(ch1), .I_tmds_channel_2(ch2),
        .I_tmds_channel_clk(chclk), .O_tmds_ch0_p(HDMI_D0_P), .O_tmds_ch1_p(HDMI_D1_P),
        .O_tmds_ch2_p(HDMI_D2_P), .O_tmds_clk_p(HDMI_CLK_P));
endmodule
