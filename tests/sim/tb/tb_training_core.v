`timescale 1ns/1ps
module tb_training_core;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0,tick_ms=0,enabled=0,clear_session=0;
    reg [3:0] depth_switches=0;
    wire [31:0] press_count,rotate_remaining_ms;
    wire [15:0] interval_ms,pause_ms;
    wire [1:0] rate_grade,depth_grade;
    wire rate_valid,pause_warning,rotate_due,beat_event,compression_event,sensor_fault;
    training_core #(.PAUSE_WARN_MS(700),.ROTATE_MS(2000)) dut(
        clk,rst_n,tick_ms,enabled,clear_session,depth_switches,
        press_count,interval_ms,rate_valid,rate_grade,depth_grade,
        pause_ms,pause_warning,rotate_remaining_ms,rotate_due,
        beat_event,compression_event,sensor_fault,1'b0,2'd0,1'b0);
    task step;
        begin @(posedge clk); #1; @(negedge clk); end
    endtask
    task wait_ms;
        input integer duration; integer i;
        begin
            for(i=0;i<duration;i=i+1) begin tick_ms=1; step; end
            tick_ms=0;
        end
    endtask
    task press;
        input [3:0] pattern;
        begin depth_switches=pattern; step; step;
            depth_switches=0; step; end
    endtask
    task check;
        input condition; input [511:0] message;
        begin if (condition !== 1'b1) begin $display("FAIL: %0s",message); $fatal(1); end end
    endtask
    initial begin
        #2; rst_n=0; step; rst_n=1; enabled=1; step; step;
        press(4'b0001);
        check(press_count==1 && depth_grade==1 && !rate_valid,"first shallow press");
        wait_ms(500); press(4'b0011);
        check(interval_ms==500 && rate_grade==2 && rate_valid,"500ms inclusive");
        wait_ms(600); press(4'b1111);
        check(interval_ms==600 && rate_grade==2 && depth_grade==3,"600ms inclusive/deep");
        wait_ms(499); press(4'b0111);
        check(rate_grade==3,"499ms fast");
        wait_ms(601); press(4'b0001);
        check(rate_grade==1,"601ms slow");
        depth_switches=4'b0011; step; depth_switches=4'b1111; step;
        depth_switches=4'b0001; step;
        check(press_count==5,"no counting while held");
        depth_switches=0; step;
        check(press_count==6 && depth_grade==3,"peak retained through release");
        press(4'b0100);
        check(sensor_fault && depth_grade==0,"invalid switch ordering");
        wait_ms(700); check(pause_warning,"pause warning");
        check(rotate_due && rotate_remaining_ms==0,"rotation countdown latches");
        press(4'b0011); check(!pause_warning && !sensor_fault,"recovery");
        clear_session=1; step; clear_session=0; step;
        check(press_count==0 && !rate_valid && !rotate_due,"session reset");
        enabled=0; step; wait_ms(800);
        check(!pause_warning && !beat_event,"disabled training");

        // A press held outside this session must first release to arm.
        // Its release cannot masquerade as a fresh completed compression.
        depth_switches=4'b0011; step; enabled=1; step; step; step;
        check(press_count==0 && !compression_event && depth_grade==0,
              "held input on training entry stays cancelled");
        depth_switches=0; step;
        check(press_count==0 && !compression_event && !rate_valid,
              "release after held training entry only arms");
        step; press(4'b0011);
        check(press_count==1 && compression_event && depth_grade==2 && !rate_valid,
              "fresh press works after entry release arms");
        step;
        check(!compression_event && press_count==1,
              "fresh completion is a single clock pulse");

        // Clear cancels an in-flight press even if the switch remains held.
        depth_switches=4'b1111; step; step;
        clear_session=1; step; clear_session=0; step; step; step;
        check(press_count==0 && !compression_event && depth_grade==0,
              "held input after session clear stays cancelled");
        depth_switches=0; step;
        check(press_count==0 && !compression_event && !rate_valid,
              "release after held session clear only arms");
        step; press(4'b1111);
        check(press_count==1 && compression_event && depth_grade==3 && !rate_valid,
              "fresh deep press works after clear release arms");
        step;
        check(!compression_event && press_count==1,
              "post-clear completion cannot replay on an idle clock");
        $display("PASS: training core behavior"); $finish;
    end
    initial begin #1000000; $fatal(1,"timeout"); end
endmodule
