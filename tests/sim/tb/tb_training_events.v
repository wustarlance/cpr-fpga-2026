`timescale 1ns/1ps
module tb_training_events;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg tick_ms = 0;
    reg enabled = 0;
    reg clear_session = 0;
    // Invalid switch ordering is deliberate: event mode must ignore it.
    reg [3:0] depth_switches = 4'b0100;
    reg press_event = 0;
    reg [1:0] press_grade = 0;
    reg press_fault = 0;
    wire [31:0] press_count, rotate_remaining_ms;
    wire [15:0] interval_ms, pause_ms;
    wire rate_valid, pause_warning, rotate_due, beat_event, compression_event, sensor_fault;
    wire [1:0] rate_grade, depth_grade;
    integer checked_events = 0;
    integer j;

    training_core #(.USE_PRESS_EVENTS(1), .PAUSE_WARN_MS(8), .ROTATE_MS(20), .BEAT_MS(5)) dut (
        .clk(clk), .rst_n(rst_n), .tick_ms(tick_ms), .enabled(enabled),
        .clear_session(clear_session), .depth_switches(depth_switches),
        .press_count(press_count), .interval_ms(interval_ms), .rate_valid(rate_valid),
        .rate_grade(rate_grade), .depth_grade(depth_grade), .pause_ms(pause_ms),
        .pause_warning(pause_warning), .rotate_remaining_ms(rotate_remaining_ms),
        .rotate_due(rotate_due), .beat_event(beat_event),
        .compression_event(compression_event), .sensor_fault(sensor_fault),
        .press_event(press_event), .press_grade(press_grade), .press_fault(press_fault));

    task check;
        input condition;
        input [767:0] message;
        begin
            if (condition !== 1'b1) $fatal(1, "FAIL tb_training_events: %0s", message);
        end
    endtask

    task cycle;
        input integer tick;
        input integer event_input;
        input integer grade;
        input integer fault;
        begin
            @(negedge clk);
            tick_ms = tick;
            press_event = event_input;
            press_grade = grade;
            press_fault = fault;
            @(posedge clk); #1;
        end
    endtask

    task wait_ms;
        input integer duration;
        integer k;
        begin
            // Accelerated model: one asserted tick represents one logical
            // millisecond, independent of the bench's 10 ns clock period.
            for (k = 0; k < duration; k = k + 1) begin
                cycle(1, 0, 0, 0);
                check(!compression_event, "tick without event must not compress");
            end
            cycle(0, 0, 0, 0);
        end
    endtask

    task event_checked;
        input integer grade;
        input [31:0] expected_count;
        input integer expected_rate_valid;
        input integer expected_interval;
        input integer expected_rate_grade;
        input integer coincident_tick;
        begin
            cycle(coincident_tick, 1, grade, 0);
            checked_events = checked_events + 1;
            check(compression_event, "accepted completion event pulse");
            check(press_count === expected_count, "press counter / saturation");
            check(depth_grade === grade, "event grade must be retained");
            check(rate_valid === (expected_rate_valid != 0), "rate_valid before/after first event");
            check(interval_ms === expected_interval, "elapsed interval includes coincident tick");
            check(rate_grade === expected_rate_grade, "rate interval boundary classification");
            check(!sensor_fault, "clean event clears fault and ignores depth switches");
            check(pause_ms == 0 && !pause_warning, "completion resets pause clock");
            cycle(0, 0, 0, 0);
            check(!compression_event, "completion output must clear on next app clock");
            check(press_count === expected_count && depth_grade === grade,
                "completion result holds between events");
        end
    endtask

    task clear_all;
        begin
            clear_session = 1;
            cycle(1, 1, 3, 1);
            check(press_count == 0 && interval_ms == 0 && !rate_valid &&
                depth_grade == 0 && rate_grade == 0 && !compression_event &&
                !sensor_fault && pause_ms == 0 && !pause_warning &&
                rotate_remaining_ms == 20 && !rotate_due,
                "clear has priority over tick, event and fault");
            clear_session = 0;
            cycle(0, 0, 0, 0);
            check(!beat_event && !compression_event, "clear pulse ends");
        end
    endtask

    initial begin
        repeat (2) @(negedge clk);
        rst_n = 1;
        cycle(0, 0, 0, 0);
        enabled = 1;
        cycle(1, 1, 3, 0);
        check(press_count == 0 && !compression_event && !rate_valid && beat_event,
            "first enabled edge resets session and discards coincident event");
        cycle(0, 0, 0, 0);
        check(!beat_event && !pause_warning, "enabled startup pulse ends");
        event_checked(1, 1, 0, 0, 0, 0);
        wait_ms(499); event_checked(2, 2, 1, 499, 3, 0);
        wait_ms(500); event_checked(3, 3, 1, 500, 2, 0);
        wait_ms(600); event_checked(1, 4, 1, 600, 2, 0);
        wait_ms(601); event_checked(2, 5, 1, 601, 1, 0);
        wait_ms(499); event_checked(2, 6, 1, 500, 2, 1);
        wait_ms(599); event_checked(3, 7, 1, 600, 2, 1);
        wait_ms(600); event_checked(1, 8, 1, 601, 1, 1);
        wait_ms(498); event_checked(2, 9, 1, 499, 3, 1);
        event_checked(3, 10, 1, 0, 3, 0);

        cycle(0, 1, 1, 1);
        check(press_count == 10 && !compression_event && sensor_fault && depth_grade == 3,
            "fault rejects event without changing stored class");
        cycle(0, 0, 0, 1);
        check(sensor_fault && press_count == 10, "fault display without completed event");
        cycle(0, 0, 0, 0);
        check(sensor_fault && !compression_event, "fault display retains until valid recovery");
        event_checked(2, 11, 1, 0, 3, 0);

        enabled = 0;
        cycle(1, 1, 3, 1);
        check(press_count == 0 && !compression_event && !sensor_fault &&
            !rate_valid && depth_grade == 0 && !beat_event && rotate_remaining_ms == 20,
            "disable discards coincident tick/event and resets counters");
        cycle(1, 1, 2, 0);
        check(press_count == 0 && !compression_event && !pause_warning,
            "disabled events cannot count");
        enabled = 1;
        cycle(0, 1, 3, 0);
        check(press_count == 0 && !compression_event, "re-enable edge discards stale event");
        cycle(0, 0, 0, 0);
        event_checked(3, 1, 0, 0, 0, 0);
        clear_all();
        event_checked(2, 1, 0, 0, 0, 0);

        clear_all();
        wait_ms(8);
        check(!pause_warning && pause_ms == 0, "no pause warning before first completion");
        clear_all();
        event_checked(1, 1, 0, 0, 0, 0);
        wait_ms(7);
        check(pause_ms == 7 && !pause_warning, "pause lower boundary");
        wait_ms(1);
        check(pause_ms == 8 && pause_warning, "pause threshold inclusive");
        event_checked(2, 2, 1, 8, 3, 0);
        wait_ms(12);
        check(rotate_remaining_ms == 0 && rotate_due, "rotation countdown reaches zero");
        wait_ms(10);
        check(rotate_remaining_ms == 0 && rotate_due, "rotation due latches without underflow");

        clear_all();
        for (j = 0; j < 4; j = j + 1) begin
            cycle(1, 0, 0, 0);
            check(!beat_event, "beat must not be early");
        end
        cycle(1, 0, 0, 0);
        check(beat_event, "fifth tick produces beat");
        cycle(0, 0, 0, 0);
        check(!beat_event, "beat pulse clears even without next tick");

        clear_all();
        event_checked(1, 1, 0, 0, 0, 0);
        // Finite-state arithmetic boundaries: preload counters in the
        // bench instead of simulating billions of completed compressions.
        dut.press_count = 32'hfffffffe;
        dut.elapsed_ms = 16'hfffe;
        dut.pause_ms = 16'hfffe;
        cycle(1, 0, 0, 0);
        check(dut.elapsed_ms == 16'hffff && pause_ms == 16'hffff,
            "elapsed and pause reach saturated maximum");
        cycle(1, 0, 0, 0);
        check(dut.elapsed_ms == 16'hffff && pause_ms == 16'hffff,
            "elapsed and pause must not wrap");
        event_checked(2, 32'hffffffff, 1, 65535, 1, 1);
        event_checked(3, 32'hffffffff, 1, 0, 3, 0);
        clear_all();
        check(press_count == 0 && dut.elapsed_ms == 0 && pause_ms == 0,
            "clear also clears saturated counters");

        $display("PASS tb_training_events checked_events=%0d", checked_events);
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "TIMEOUT tb_training_events");
    end
endmodule
