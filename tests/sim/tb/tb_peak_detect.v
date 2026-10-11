`timescale 1ns/1ps
module tb_peak_detect;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;
    reg enabled = 1'b1;
    reg clear_session = 1'b0;
    reg sample_valid = 1'b0;
    reg [11:0] sample_data = 12'd0;
    wire peak_valid, in_press;
    wire [11:0] peak_value;
    wire [1:0] depth_grade;
    integer events = 0;
    integer samples = 0;
    reg previous_peak_valid = 1'b0;
    peak_detect dut (
        .clk(clk), .rst_n(rst_n), .enabled(enabled), .clear_session(clear_session),
        .sample_valid(sample_valid), .sample_data(sample_data),
        .peak_valid(peak_valid), .peak_value(peak_value),
        .depth_grade(depth_grade), .in_press(in_press));

    always @(posedge clk) begin
        #2;
        if (!rst_n) previous_peak_valid = 0;
        else begin
            if (peak_valid !== 0 && peak_valid !== 1)
                $fatal(1, "FAIL unknown peak_valid");
            if (peak_valid && previous_peak_valid)
                $fatal(1, "FAIL completion longer than one system clock");
            previous_peak_valid = peak_valid;
        end
    end

    task idle;
        input integer clocks;
        integer k;
        begin
            for (k = 0; k < clocks; k = k + 1) begin
                @(negedge clk); sample_valid = 0;
                @(posedge clk); #1;
                if (peak_valid !== 0)
                    $fatal(1, "FAIL peak_valid persisted without accepted sample");
            end
        end
    endtask

    task sample;
        input integer code;
        input integer expected_event;
        input integer expected_peak;
        input integer expected_grade;
        input integer expected_press;
        begin
            @(negedge clk); sample_valid = 1; sample_data = code;
            @(posedge clk); #1;
            samples = samples + 1;
            if (peak_valid !== (expected_event != 0) || in_press !== (expected_press != 0))
                $fatal(1, "FAIL sample=%0d code=%0d event=%b expected=%0d in_press=%b expected=%0d",
                    samples, code, peak_valid, expected_event, in_press, expected_press);
            if (expected_event) begin
                if (peak_value !== expected_peak || depth_grade !== expected_grade)
                    $fatal(1, "FAIL peak=%0d grade=%0d expected=%0d/%0d",
                        peak_value, depth_grade, expected_peak, expected_grade);
                events = events + 1;
            end
            @(negedge clk); sample_valid = 0;
        end
    endtask

    task complete_press;
        input integer peak;
        input integer grade;
        begin
            sample(150, 0, 0, 0, 1); // trigger boundary is inclusive
            idle(3);
            sample(peak, 0, 0, 0, 1);
            sample(101, 0, 0, 0, 1); // just above release cannot complete
            idle(7);
            sample(100, 1, peak, grade, 0); // full release boundary inclusive
            idle(8); // event pulse must clear long before next valid sample
            sample(0, 0, 0, 0, 0);
            sample(100, 0, 0, 0, 0); // repeated release cannot count twice
        end
    endtask

    task cancel_with_clear;
        begin
            @(negedge clk); clear_session = 1; sample_valid = 1; sample_data = 0;
            @(posedge clk); #1;
            if (in_press !== 0 || peak_valid !== 0 || peak_value !== 0 || depth_grade !== 0)
                $fatal(1, "FAIL clear must take precedence over release");
            @(negedge clk); clear_session = 0; sample_valid = 0;
        end
    endtask

    initial begin
        repeat (2) @(negedge clk);
        rst_n = 1;
        sample(1500, 0, 0, 0, 0); // initial pressure cannot arm
        sample(1000, 0, 0, 0, 0);
        sample(100, 0, 0, 0, 0); // arm only upon full release
        sample(149, 0, 0, 0, 0);
        idle(2);
        sample(120, 0, 0, 0, 0);
        sample(0, 0, 0, 0, 0); // sub-trigger noise makes no event
        complete_press(799, 1);
        complete_press(800, 2);
        complete_press(1600, 2);
        complete_press(1601, 3);
        complete_press(4095, 3);

        sample(150, 0, 0, 0, 1);
        sample(1500, 0, 0, 0, 1);
        sample(900, 0, 0, 0, 1); // >25% fall still is not full release
        idle(5);
        sample(1400, 0, 0, 0, 1);
        sample(101, 0, 0, 0, 1);
        sample(0, 1, 1500, 2, 0);
        idle(9);

        sample(900, 0, 0, 0, 1);
        cancel_with_clear();
        sample(1700, 0, 0, 0, 0); // clear during pressure requires new release
        sample(1600, 0, 0, 0, 0);
        sample(100, 0, 0, 0, 0);
        complete_press(800, 2);

        sample(1200, 0, 0, 0, 1);
        @(negedge clk); enabled = 0;
        idle(2);
        if (in_press !== 0 || peak_value !== 0 || depth_grade !== 0)
            $fatal(1, "FAIL disabled state");
        sample(0, 0, 0, 0, 0); // release while disabled must not arm
        @(negedge clk); enabled = 1;
        sample(1200, 0, 0, 0, 0);
        sample(900, 0, 0, 0, 0);
        sample(0, 0, 0, 0, 0);
        complete_press(1601, 3);

        sample(1400, 0, 0, 0, 1);
        @(negedge clk); rst_n = 0; sample_valid = 0;
        #1;
        if (peak_valid !== 0 || in_press !== 0 || peak_value !== 0 || depth_grade !== 0)
            $fatal(1, "FAIL asynchronous reset");
        repeat (2) @(negedge clk);
        rst_n = 1;
        sample(1400, 0, 0, 0, 0);
        sample(900, 0, 0, 0, 0);
        sample(0, 0, 0, 0, 0);
        complete_press(150, 1);
        idle(10);
        if (events != 9) $fatal(1, "FAIL completion count %0d expected 9", events);
        $display("PASS tb_peak_detect samples=%0d events=%0d", samples, events);
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "TIMEOUT tb_peak_detect");
    end
endmodule
