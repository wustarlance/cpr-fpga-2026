`timescale 1ns/1ps
module tb_rate_display_lut;
    reg clk=0, rst_n=0, rate_valid=0;
    reg [15:0] interval_ms=0;
    wire [7:0] bpm_approx;
    wire bpm_valid;
    integer ms, expected, previous;
    always #1 clk=~clk;
    rate_display_lut dut(.clk(clk),.rst_n(rst_n),.interval_ms(interval_ms),
        .rate_valid(rate_valid),.bpm_approx(bpm_approx),.bpm_valid(bpm_valid));
    task settle;
        input integer value;
        begin @(negedge clk);interval_ms=value;rate_valid=1;repeat(18)@(negedge clk);end
    endtask
    initial begin
        repeat(3)@(negedge clk);rst_n=1;
        previous=255;
        for(ms=0;ms<65536;ms=ms+1)begin
            settle(ms);
            if(ms<235)begin
                if(bpm_valid!==0 || bpm_approx!==0)$fatal(1,"invalid interval accepted ms=%0d",ms);
            end else begin
                expected=(60000+ms/2)/ms;
                if(bpm_valid!==1 || bpm_approx!==expected || bpm_approx>previous)
                    $fatal(1,"rate disappeared/wrong ms=%0d got=%0d valid=%b expected=%0d",ms,bpm_approx,bpm_valid,expected);
                previous=bpm_approx;
            end
        end
        settle(1000);
        @(negedge clk);interval_ms=1096;
        repeat(3)@(negedge clk);
        if(!bpm_valid || bpm_approx!=60)$fatal(1,"old result blinked during recalculation");
        repeat(15)@(negedge clk);
        if(!bpm_valid || bpm_approx!=55)$fatal(1,"photo regression: 1096ms must show 55 BPM");
        @(negedge clk);interval_ms=500;
        repeat(4)@(negedge clk);interval_ms=750;
        repeat(18)@(negedge clk);
        if(!bpm_valid || bpm_approx!=80)$fatal(1,"in-flight input replacement failed");
        @(negedge clk);interval_ms=545;
        repeat(4)@(negedge clk);rate_valid=0;
        repeat(20)@(negedge clk);
        if(bpm_valid || bpm_approx)$fatal(1,"session clear allowed stale divider completion");
        settle(400);
        @(negedge clk);rst_n=0;#0.1;
        if(bpm_valid || bpm_approx)$fatal(1,"reset did not clear display");
        @(negedge clk);rst_n=1;rate_valid=0;
        repeat(20)@(negedge clk);
        if(bpm_valid)$fatal(1,"reset result reappeared");
        $display("PASS: tb_rate_display_lut: 65536 intervals, rounding, slow/fast, hold, restart and reset");
        $finish;
    end
    initial begin #3000000;$fatal(1,"TIMEOUT rate display");end
endmodule
