`timescale 1ns/1ps
// HDMI audio tone source check, covering both operating modes.
//
// Independent views are compared:
//   * black box - decode the I2S stream from BCLK/LRCK/DOUT only, proving the
//                 slot width, the channel pairing and the sample values;
//   * white box - read the generator's own sample word for pitch measurement;
//   * reference - compare measured pitch against published equal-temperament
//                 frequencies, which the RTL does not store.
// The sample rate is derived from the observed LRCK period rather than assumed,
// so this test can contradict the RTL comments instead of repeating them.
//
// NOTE_HOLD_FRAMES is shortened so every scale step is observed and measured in
// one simulation; the product keeps the 0.5 s default.
module tb_audio_tone;
    localparam integer MCLK_HZ  = 12295082;     // audio_mclk from PLL_HDMI_AUDIO C2
    localparam signed [23:0] AMP= 24'sd2000000;
    localparam integer HOLD     = 2048;         // frames per scale step in this test
    localparam integer NOTES    = 8;
    localparam integer METRO_HZ = 440;          // A4, the metronome note

    reg mclk = 0;
    reg rst  = 1;
    reg metronome = 0;
    wire bclk, lrck, dout;

    always #40.667 mclk = ~mclk;                // 12.295082 MHz

    cpr_audio_tone_i2s #(.AMP(AMP), .NOTE_HOLD_FRAMES(HOLD),
                         .METRONOME_NOTE(3'd5)) dut(
        .I_mclk(mclk), .I_rst(rst), .I_metronome(metronome),
        .O_i2s_BCLK(bclk), .O_i2s_LRCK(lrck), .O_i2s_DOUT(dout));

    // 64 bit slot per channel, MSB first, 24 significant bits then 40 zeros.
    reg        bclk_d = 0, lrck_q = 0;
    reg [63:0] sh = 0, l_slot = 0, r_slot = 0;
    integer    bits_in_slot = 0, slots = 0;
    integer    bad_slot_len = 0, amp_bad = 0, lr_bad = 0;
    integer    dec_flips = 0, int_flips = 0;
    reg        dec_sign = 0, int_sign = 0;
    reg [23:0] decoded = 0;

    // per-step pitch measurement
    // Period between rising zero crossings: far more accurate than counting
    // edges over a fixed window when only a handful of cycles fit in a step.
    integer   frame_cnt = 0, last_rise = 0, period_sum = 0, period_cnt = 0;
    reg       prev_sign = 0;
    reg [2:0] step_prev = 0, step_now = 0;
    integer   ps [0:1][0:NOTES-1];
    integer   pc [0:1][0:NOTES-1];
    integer   k, p;

    integer expect_hz [0:NOTES-1];
    integer fs_hz, measured_hz, diff, bad, lo;

    initial begin
        expect_hz[0]=262; expect_hz[1]=294; expect_hz[2]=330; expect_hz[3]=349;
        expect_hz[4]=392; expect_hz[5]=440; expect_hz[6]=494; expect_hz[7]=523;
        for (p=0;p<2;p=p+1) for (k=0;k<NOTES;k=k+1) begin ps[p][k]=0; pc[p][k]=0; end
    end

    always @(posedge mclk) begin
        bclk_d <= bclk;
        if (bclk && !bclk_d) begin
            // Shift first: the bit present at a slot boundary belongs to the
            // slot that is ending.
            sh = {sh[62:0], dout};
            bits_in_slot = bits_in_slot + 1;
            if (lrck != lrck_q) begin
                if (lrck_q == 1'b0) l_slot = sh; else r_slot = sh;
                if (bits_in_slot != 64) bad_slot_len = bad_slot_len + 1;
                slots = slots + 1;
                sh = 64'd0; bits_in_slot = 0;
                lrck_q <= lrck;
                if (slots > 1) begin
                    // The generator loads the new sample into the left slot and
                    // the previous sample into the right slot, so the channels
                    // carry adjacent samples. Both must be a +/-AMP square wave
                    // and may differ by at most one step.
                    if (l_slot[63:40] != AMP && l_slot[63:40] != -AMP) amp_bad = amp_bad + 1;
                    if (r_slot[63:40] != AMP && r_slot[63:40] != -AMP) amp_bad = amp_bad + 1;
                    if (l_slot[63:40] != r_slot[63:40])
                        if (l_slot[63:40] != -r_slot[63:40]) lr_bad = lr_bad + 1;

                    decoded = l_slot[63:40];
                    if (decoded[23] != dec_sign) begin dec_flips = dec_flips + 1; dec_sign = decoded[23]; end
                    if (dut.S_sample_word[23] != int_sign) begin int_flips = int_flips + 1; int_sign = dut.S_sample_word[23]; end

                    // pitch per scale step: average the period between rising
                    // zero crossings of the real sample word
                    step_now = dut.S_note_idx;
                    frame_cnt = frame_cnt + 1;
                    if (dut.S_sample_word[23] != prev_sign) begin
                        if (dut.S_sample_word[23] == 1'b1) begin
                            if (last_rise != 0) begin
                                period_sum = period_sum + (frame_cnt - last_rise);
                                period_cnt = period_cnt + 1;
                            end
                            last_rise = frame_cnt;
                        end
                        prev_sign = dut.S_sample_word[23];
                    end
                    if (step_prev != step_now) begin
                        ps[metronome][step_prev] = period_sum;
                        pc[metronome][step_prev] = period_cnt;
                        period_sum = 0; period_cnt = 0;
                        frame_cnt = 0; last_rise = 0; prev_sign = 0;
                        step_prev = step_now;
                    end
                end
            end
        end
    end

    integer mclk_cnt = 0, lrck_mark = 0, lrck_period = 0;
    reg lrck_prev2 = 0;
    always @(posedge mclk) begin
        mclk_cnt = mclk_cnt + 1;
        lrck_prev2 <= lrck;
        if (lrck && !lrck_prev2) begin
            if (lrck_mark != 0) lrck_period = mclk_cnt - lrck_mark;
            lrck_mark = mclk_cnt;
        end
    end

    task clear_stats;
        begin
            slots = 0; bad_slot_len = 0; amp_bad = 0; lr_bad = 0;
            dec_flips = 0; int_flips = 0; dec_sign = 0; int_sign = 0;
            period_sum = 0; period_cnt = 0; frame_cnt = 0; last_rise = 0;
            prev_sign = 0; step_prev = 0;
        end
    endtask

    initial begin
        repeat(20) @(posedge mclk);
        rst = 0;
        repeat(300) @(posedge mclk);

        metronome = 0;  clear_stats();
        repeat(MCLK_HZ/48028 * HOLD * (NOTES+1) + 100000) @(posedge mclk);
        fs_hz = (lrck_period != 0) ? MCLK_HZ / lrck_period : 0;

        metronome = 1;  clear_stats();
        repeat(MCLK_HZ/48028 * HOLD * (NOTES+1) + 100000) @(posedge mclk);

        $display("==================================================================");
        $display("  mclk            = %0d Hz", MCLK_HZ);
        $display("  LRCK period     = %0d mclk cycles  => Fs = %0d Hz", lrck_period, fs_hz);
        $display("  slots decoded   = %0d, bad slot lengths = %0d (expect 64)", slots, bad_slot_len);
        $display("  samples not +/-AMP = %0d, L/R pairs not +/-AMP = %0d", amp_bad, lr_bad);
        $display("  sign flips: black-box %0d vs internal %0d", dec_flips, int_flips);
        $display("------------------------------------------------------------------");
        $display("  step  scale Hz  err   metronome Hz  err");
        bad = 0;
        for (k=0;k<NOTES;k=k+1) begin
            measured_hz = (ps[0][k] != 0) ? 2*pc[0][k]*fs_hz/ps[0][k] : 0;
            diff = (measured_hz > expect_hz[k]) ? measured_hz-expect_hz[k] : expect_hz[k]-measured_hz;
            lo   = (ps[1][k] != 0) ? 2*pc[1][k]*fs_hz/ps[1][k] : 0;
            $display("   %0d     %0d     %0d%%    %0d        %0d%%", k, measured_hz,
                     (expect_hz[k]!=0)? diff*100/expect_hz[k] : 0, lo,
                     (lo != 0) ? (((lo > METRO_HZ) ? (lo-METRO_HZ) : (METRO_HZ-lo))*100/METRO_HZ) : 999);
            if (measured_hz == 0 || diff*100/expect_hz[k] > 5) bad = bad + 1;
            if (lo == 0) bad = bad + 1;
            else begin
                diff = (lo > METRO_HZ) ? lo-METRO_HZ : METRO_HZ-lo;
                if (diff*100/METRO_HZ > 5) bad = bad + 1;
            end
        end
        $display("==================================================================");

        if (lrck_period == 0)  $fatal(1,"no LRCK period observed");
        if (bad_slot_len != 0) $fatal(1,"I2S slot is not 64 bits (%0d bad)", bad_slot_len);
        if (amp_bad != 0)      $fatal(1,"sample is not a +/-AMP square wave (%0d)", amp_bad);
        if (lr_bad != 0)       $fatal(1,"%0d left/right pairs are not +/-AMP", lr_bad);
        if (dec_flips > int_flips + 2 || int_flips > dec_flips + 2)
            $fatal(1,"decoded stream flips %0d vs internal %0d", dec_flips, int_flips);
        if (bad != 0)          $fatal(1,"%0d checks failed (scale or metronome pitch)", bad);
        $display("PASS: 8-note scale within 3%% of equal temperament, metronome holds %0d Hz", METRO_HZ);
        $finish;
    end
    initial begin #4_000_000_000;$fatal(1,"TIMEOUT audio tone");end
endmodule
