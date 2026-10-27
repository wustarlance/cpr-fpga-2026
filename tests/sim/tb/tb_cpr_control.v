`timescale 1ns/1ps
module tb_cpr_control;
    // Ten cycles per model millisecond, preserving filter/timebase ordering.
    reg clk = 0;
    always #5 clk = !clk;
    reg rst_n = 0;
    reg [5:0] raw_keys = 0;
    reg [3:0] raw_depth = 0;
    wire [1:0] mode, brightness_level, rate_grade, depth_grade;
    wire next_key_n, prev_key_n, auto_enable, training_enabled;
    wire [31:0] press_count, rotate_remaining_ms;
    wire [15:0] interval_ms, pause_ms;
    wire rate_valid, pause_warning, rotate_due, beat_event, sensor_fault;
    wire [7:0] bpm_approx;
    wire bpm_valid;
    wire subtitle_on;
    integer errors = 0;
    integer beats = 0;
    cpr_control #(.CLK_HZ(10000), .PAUSE_WARN_MS(40),
                  .ROTATE_MS(80), .BEAT_MS(11)) dut (
        .clk(clk), .rst_n(rst_n), .raw_keys(raw_keys), .raw_depth(raw_depth),
        .mode(mode), .brightness_level(brightness_level),
        .next_key_n(next_key_n), .prev_key_n(prev_key_n),
        .auto_enable(auto_enable), .training_enabled(training_enabled),
        .press_count(press_count), .interval_ms(interval_ms),
        .rate_valid(rate_valid), .rate_grade(rate_grade), .depth_grade(depth_grade),
        .pause_ms(pause_ms), .pause_warning(pause_warning),
        .rotate_remaining_ms(rotate_remaining_ms), .rotate_due(rotate_due),
        .beat_event(beat_event), .sensor_fault(sensor_fault),
        .bpm_approx(bpm_approx), .bpm_valid(bpm_valid),
        .subtitle_on(subtitle_on),
        .press_event(1'b0), .press_grade(2'd0), .press_fault(1'b0)
    );
    always @(posedge clk) if (rst_n && beat_event) beats = beats + 1;
    task wait_ms;
        input integer amount;
        integer cycles;
        begin
            for (cycles=0; cycles<amount*10; cycles=cycles+1) @(negedge clk);
        end
    endtask
    task key_press;
        input integer index;
        begin
            raw_keys[index] = 1; wait_ms(35);
            raw_keys[index] = 0; wait_ms(25);
        end
    endtask
    task full_press;
        begin
            raw_depth = 4'b0011; wait_ms(12);
            raw_depth = 0; wait_ms(12);
        end
    endtask
    task check;
        input condition;
        input [8*96-1:0] message;
        begin
            if (condition !== 1'b1) begin
                $display("FAIL: %0s", message); errors = errors + 1;
            end
        end
    endtask
    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1; wait_ms(2);
        check(mode == 0 && brightness_level == 3 && !auto_enable,
              "reset enters teaching at full brightness");
        check(subtitle_on == 1, "subtitle defaults to on after reset");
        key_press(5);
        check(subtitle_on == 0, "K7 press turns the subtitle off");
        key_press(5);
        check(subtitle_on == 1, "second K7 press turns it back on");
        key_press(5);
        check(subtitle_on == 0 && mode == 0 && brightness_level == 3,
              "K7 only touches the subtitle, not mode or brightness");
        raw_keys[0] = 1; wait_ms(5); raw_keys[0] = 0; wait_ms(25);
        check(mode == 0, "short key bounce cannot change mode");
        raw_keys[2] = 1; wait_ms(25);
        check(!next_key_n && prev_key_n, "next level is routed in teaching");
        raw_keys[2] = 0; wait_ms(25);
        raw_keys[1] = 1; wait_ms(25);
        check(!prev_key_n && next_key_n, "previous level is routed in teaching");
        raw_keys[1] = 0; wait_ms(25);
        key_press(3);
        check(brightness_level == 0, "brightness wraps from three to zero");
        key_press(3); key_press(3); key_press(3);
        check(brightness_level == 3, "brightness covers all four levels");
        key_press(0);
        check(mode == 1 && auto_enable, "first mode press starts auto playback");
        raw_keys[2] = 1; wait_ms(80);
        check(!auto_enable && next_key_n && prev_key_n,
              "held auto pause toggles once without manual SD next");
        raw_keys[2] = 0; wait_ms(25); key_press(2);
        check(auto_enable, "auto pause toggles back to playback");
        key_press(0);
        check(mode == 2 && training_enabled && !auto_enable &&
              next_key_n && prev_key_n && press_count == 0 && !pause_warning,
              "training entry clears session and suppresses SD keys");
        raw_depth = 4'b0011; wait_ms(1); raw_depth = 0; wait_ms(8);
        check(press_count == 0, "short depth glitch is filtered");
        raw_depth = 4'b0011; wait_ms(35);
        check(press_count == 0, "held compression does not count before release");
        raw_depth = 0; wait_ms(12);
        check(press_count == 1 && depth_grade == 2 && !rate_valid && !sensor_fault,
              "first complete target-depth compression counts once");
        wait_ms(50);
        check(pause_warning, "interruption warning begins after completed press");
        // First filtered release was about nine ms before the wait ended.
        // With the 517 ms idle gap and the next press, interval is about 541 ms.
        wait_ms(467); full_press;
        check(press_count == 2 && rate_valid && rate_grade == 2 &&
              interval_ms >= 500 && interval_ms <= 600 && bpm_valid,
              "second target-rate compression produces LUT display");
        check(rotate_due && rotate_remaining_ms == 0 && beats > 4,
              "rotation deadline saturates while metronome keeps pulsing");
        key_press(4);
        check(press_count == 0 && !rate_valid && !pause_warning && !sensor_fault,
              "clear key restarts current training session");
        full_press;
        check(press_count == 1, "new compression works after session clear");
        key_press(0);
        check(mode == 0 && !training_enabled && press_count == 0,
              "mode cycle exits training and clears its counters");
        key_press(0);
        check(mode == 1 && auto_enable, "reentering auto starts playback");
        key_press(0);
        check(mode == 2 && press_count == 0 && !rate_valid,
              "reentering training starts a fresh session");
        rst_n = 0; repeat (3) @(negedge clk);
        check(mode == 0 && press_count == 0 && brightness_level == 3 && subtitle_on == 1,
              "asynchronous reset restores application state (subtitle back on)");
        if (errors == 0) $display("PASS: cpr_control integration test");
        else $fatal(1, "cpr_control errors=%0d", errors);
        $finish;
    end
    initial begin
        #1000000; $fatal(1, "cpr_control timeout");
    end
endmodule
