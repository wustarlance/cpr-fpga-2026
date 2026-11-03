`timescale 1ns/1ps
// Real top-level wiring and raster/control/ROM; SD/PCM/PHY are boundary stimuli.
// This does not measure monitor lock time, Flash configuration, or card latency.
module tb_top_startup_av;
    reg clk=0, rst_n=0;
    reg [6:0] panel=7'h7f;
    always #10 clk=~clk;
    top #(.ENABLE_AUDIO_VISUALIZATION(0), .ENABLE_SMOOTH_TRANSITIONS(0)) dut(
        .clk(clk), .rst_n(rst_n), .key1(1'b1), .key2(1'b1), .key3(1'b1),
        .key_panel_n(panel), .ext_keys_n(5'b11111), .depth_sw_n(4'hf),
        .dip_sw(4'b0000), .sd_miso(1'b1));
    // Only debounce time and logo dwell are accelerated. Real 640x480 timing
    // and the unchanged million-cycle power-on qualification are exercised.
    defparam dut.u_control.CLK_HZ=1000;
    defparam dut.u_splash.DWELL_CYCLES=64;
    integer cycles=0, first_sof=-1, audio_at=-1;
    reg logo_pixels_seen=0, prior_splash=1;
    reg phase_check=0;
    always @(posedge dut.video_clk) begin
        cycles=cycles+1;
        if (!dut.rst_video) begin
            if (dut.axis_s_valid && dut.axis_s_data!=0 && dut.splash_on)
                logo_pixels_seen=1;
            if (dut.splash_on || !dut.app_rst_n || !dut.display_valid_sync[1]) begin
                if (dut.hdmi_audio_left!==0 || dut.hdmi_audio_right!==0 ||
                    dut.wav_play_gate!==0 || dut.heart_en!==0)
                    $fatal(1,"startup/no-picture audio leaked or player advanced");
                if (dut.audio_output_valid!==1 || dut.acr_output_valid!==1)
                    $fatal(1,"silence must retain PCM/ACR cadence");
            end
            if (phase_check) begin
                if (!dut.splash_on && prior_splash && dut.visual_de)
                    $fatal(1,"logo handed over in active video");
                if (!dut.splash_on && dut.axis_s_valid && dut.axis_s_user && first_sof<0)
                    first_sof=cycles;
                if (dut.media_audio_enable && audio_at<0) begin
                    audio_at=cycles;
                    if (first_sof<0 || cycles-first_sof<640*480)
                        $fatal(1,"audio enabled before one tutorial frame was sent");
                end
            end
            prior_splash=dut.splash_on;
        end
    end
    task settle;
        begin repeat(35) @(negedge dut.video_clk); end
    endtask
    task press(input integer bit_index);
        begin panel[bit_index]=0; settle; panel[bit_index]=1; settle; end
    endtask
    reg [2:0] old_contrast;
    reg old_subtitle;
    integer mode_index;
    initial begin
        #100;
        if(dut.contrast_video!==3'd3)
            $fatal(1,"reset picture contrast must be 100%%");
        #100;
        rst_n=1;
        dut.video_pll_m0.model_locked=1;
        wait(logo_pixels_seen);
        if (dut.app_rst_n!==0 || dut.por_ready!==0)
            $fatal(1,"logo test must precede other PLLs and application release");
        $display("INFO BRAM logo streams while SD/audio PLL locks are absent");
        dut.sys_pll_m0.model_locked=1;
        dut.u_audio_pll.model_locked=1;
        wait(dut.app_rst_n);
        settle;
        // Distinct physical K6 and K7, repeated/held/simultaneous, in all modes.
        for(mode_index=0;mode_index<3;mode_index=mode_index+1) begin
            old_contrast=dut.contrast_level; old_subtitle=dut.subtitle_on;
            panel[5]=0; settle;
            if (dut.contrast_level==old_contrast || dut.subtitle_on!==old_subtitle)
                $fatal(1,"K6 changed subtitle or failed to step contrast");
            old_contrast=dut.contrast_level;
            settle;
            if (dut.contrast_level!==old_contrast)
                $fatal(1,"held K6 repeated");
            panel[5]=1; settle;
            press(6);
            if (dut.contrast_level!==old_contrast || dut.subtitle_on===old_subtitle)
                $fatal(1,"K7 changed contrast or failed to toggle subtitle");
            press(6);
            if (dut.subtitle_on!==old_subtitle) $fatal(1,"K7 did not toggle back");
            panel[6:5]=0; settle;
            if (dut.contrast_level==old_contrast || dut.subtitle_on===old_subtitle)
                $fatal(1,"simultaneous K6/K7 did not operate independently");
            panel[6:5]=2'b11; settle;
            press(0);
        end
        $display("INFO K6 contrast and K7 subtitle independent in three modes");
        force dut.display_valid=1'b1;
        // A page exists behind the logo; preload is deliberately not done yet.
        settle;
        if (dut.splash_on!==1 || dut.media_audio_enable!==0)
            $fatal(1,"cached picture behind logo incorrectly enabled sound");
        // Training selected during boot must not leak a heartbeat either.
        press(0); press(0); settle;
        if (dut.training_enabled!==1 || dut.heart_en!==0)
            $fatal(1,"training bypassed startup silence");
        press(0);
        wait(dut.visual_de);
        @(negedge dut.video_clk);
        force dut.boot_load_done_sd=1'b1;
        phase_check=1;
        wait(!dut.splash_on);
        wait(dut.media_audio_enable);
        settle;
        if (dut.wav_play_gate!==1 || dut.hdmi_audio_left!==24'h123456 ||
            dut.hdmi_audio_right!==24'h654321)
            $fatal(1,"audio did not start after visible tutorial");
        $display("INFO first tutorial SOF=%0d audio=%0d",first_sof,audio_at);
        force dut.display_valid=1'b0;
        settle;
        if (dut.media_audio_enable!==0 || dut.hdmi_audio_left!==0)
            $fatal(1,"loss of picture did not silence audio");
        rst_n=0; settle;
        if (dut.splash_on!==1 || dut.media_audio_enable!==0)
            $fatal(1,"reset did not restore silent logo");
        $display("PASS: top_startup_av early logo, frame-qualified audio and physical K6/K7");
        $finish;
    end
    initial begin #300000000; $fatal(1,"top startup timeout"); end
endmodule
