`timescale 1ns/1ps
module tb_pressure_normalize;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;
    reg adc_valid = 1'b0;
    reg [11:0] adc_data = 12'd0;
    wire falling_valid, rising_valid, average_valid, maximum_valid, maximum_average_valid;
    wire [11:0] falling_data, rising_data, average_data, maximum_data, maximum_average_data;

    pressure_normalize #(.FILTER_SHIFT(0)) falling (
        .clk(clk), .rst_n(rst_n), .adc_valid(adc_valid), .adc_data(adc_data),
        .pressure_valid(falling_valid), .pressure_data(falling_data));
    pressure_normalize #(.FALLING_WITH_FORCE(0), .FILTER_SHIFT(0)) rising (
        .clk(clk), .rst_n(rst_n), .adc_valid(adc_valid), .adc_data(adc_data),
        .pressure_valid(rising_valid), .pressure_data(rising_data));
    pressure_normalize #(.FILTER_SHIFT(2)) average (
        .clk(clk), .rst_n(rst_n), .adc_valid(adc_valid), .adc_data(adc_data),
        .pressure_valid(average_valid), .pressure_data(average_data));
    pressure_normalize #(.RELEASE_BASELINE(12'd4095), .FILTER_SHIFT(0)) maximum (
        .clk(clk), .rst_n(rst_n), .adc_valid(adc_valid), .adc_data(adc_data),
        .pressure_valid(maximum_valid), .pressure_data(maximum_data));
    pressure_normalize #(.RELEASE_BASELINE(12'd4095), .FILTER_SHIFT(2)) maximum_average (
        .clk(clk), .rst_n(rst_n), .adc_valid(adc_valid), .adc_data(adc_data),
        .pressure_valid(maximum_average_valid), .pressure_data(maximum_average_data));

    integer past [0:3];
    integer maximum_past [0:3];
    integer accepted;
    integer expected_falling, expected_rising, expected_maximum, expected_average, expected_maximum_average;
    integer total, j, i, transactions;

    task reset_reference;
        begin
            accepted = 0;
            expected_falling = 0;
            expected_rising = 0;
            expected_maximum = 0;
            expected_average = 0;
            expected_maximum_average = 0;
            for (j = 0; j < 4; j = j + 1) begin
                past[j] = 0;
                maximum_past[j] = 0;
            end
        end
    endtask

    task drive;
        input integer valid;
        input integer code;
        integer expected_average_valid;
        begin
            @(negedge clk);
            adc_valid = valid;
            adc_data = code;
            expected_average_valid = 0;
            if (valid) begin
                expected_falling = (code < 3000) ? (3000 - code) : 0;
                expected_rising = (code > 3000) ? (code - 3000) : 0;
                expected_maximum = 4095 - code;
                // Independent queue model: mean of last four accepted
                // samples. Invalid cycles are deliberately absent.
                for (j = 0; j < 3; j = j + 1) begin
                    past[j] = past[j+1];
                    maximum_past[j] = maximum_past[j+1];
                end
                past[3] = expected_falling;
                maximum_past[3] = expected_maximum;
                accepted = accepted + 1;
                if (accepted >= 4) begin
                    total = past[0] + past[1] + past[2] + past[3];
                    expected_average = total / 4;
                    total = maximum_past[0] + maximum_past[1] + maximum_past[2] + maximum_past[3];
                    expected_maximum_average = total / 4;
                    expected_average_valid = 1;
                end
                transactions = transactions + 1;
            end
            @(posedge clk); #1;
            if (falling_valid !== (valid != 0) || rising_valid !== (valid != 0) ||
                maximum_valid !== (valid != 0) ||
                average_valid !== (expected_average_valid != 0) ||
                maximum_average_valid !== (expected_average_valid != 0))
                $fatal(1, "FAIL valid alignment code=%0d accepted=%0d", code, accepted);
            if (falling_data !== expected_falling || rising_data !== expected_rising ||
                maximum_data !== expected_maximum || average_data !== expected_average)
                $fatal(1, "FAIL code=%0d got fall/rise/max/avg=%0d/%0d/%0d/%0d expected=%0d/%0d/%0d/%0d",
                    code, falling_data, rising_data, maximum_data, average_data,
                    expected_falling, expected_rising, expected_maximum, expected_average);
            if (maximum_average_data !== expected_maximum_average)
                $fatal(1, "FAIL full-range average=%0d expected=%0d", maximum_average_data, expected_maximum_average);
        end
    endtask

    task apply_reset;
        begin
            @(negedge clk); rst_n = 0; adc_valid = 0;
            reset_reference();
            #1;
            if (falling_valid !== 0 || rising_valid !== 0 || average_valid !== 0 || maximum_valid !== 0 || maximum_average_valid !== 0 ||
                falling_data !== 0 || rising_data !== 0 || average_data !== 0 || maximum_data !== 0 || maximum_average_data !== 0)
                $fatal(1, "FAIL reset output");
            @(negedge clk); rst_n = 1;
        end
    endtask

    initial begin
        transactions = 0;
        reset_reference();
        repeat (2) @(negedge clk);
        rst_n = 1;
        drive(0, 4095);
        drive(1, 3000);
        drive(0, 0);
        drive(1, 2999);
        drive(1, 3001);
        drive(0, 0);
        drive(1, 0);
        drive(1, 4095);
        drive(1, 2997); // fractional mean truncates downward
        for (i = 0; i < 96; i = i + 1) begin
            drive(1, (i * 137) % 4096);
            if ((i % 4) == 1) drive(0, 17);
            if ((i % 4) == 3) begin drive(0, 4095); drive(0, 0); end
        end
        apply_reset();
        drive(1, 0);
        drive(0, 0);
        drive(1, 0);
        apply_reset(); // discard incomplete filter window
        drive(1, 0);
        drive(1, 0);
        drive(1, 0);
        drive(0, 4095);
        drive(1, 0);
        drive(1, 0);
        drive(0, 0);
        $display("PASS tb_pressure_normalize accepted=%0d", transactions);
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "TIMEOUT tb_pressure_normalize");
    end
endmodule
