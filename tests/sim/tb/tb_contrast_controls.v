`timescale 1ns/1ps
module tb_contrast_controls;
    reg clk=0,rst_n=0,training=0;
    reg [2:0] raw=0;
    wire [2:0] held,live;
    reg [3:0] divider=0;
    wire tick_ms=divider==9;
    always #5 clk=~clk;
    always @(posedge clk) divider<=divider==9 ? 0 : divider+1;
    contrast_controls #(.STABLE_MS(3),.HOLD_DURING_TRAINING(1)) h(
        .clk(clk),.rst_n(rst_n),.tick_ms(tick_ms),.raw_switches(raw),
        .training_enabled(training),.contrast_level(held));
    contrast_controls #(.STABLE_MS(3),.HOLD_DURING_TRAINING(0)) l(
        .clk(clk),.rst_n(rst_n),.tick_ms(tick_ms),.raw_switches(raw),
        .training_enabled(training),.contrast_level(live));
    task set_switch(input [2:0] code);
        begin @(negedge clk);raw=code;repeat(80)@(negedge clk);end
    endtask
    initial begin
        repeat(3)@(negedge clk);rst_n=1;repeat(5)@(negedge clk);
        if(held!==2 || live!==2)$fatal(1,"neutral startup");
        raw=1;@(negedge clk);raw=0;repeat(80)@(negedge clk);
        if(held!==2 || live!==2)$fatal(1,"short switch glitch changed setting");
        set_switch(1);if(held!==0 || live!==0)$fatal(1,"low contrast mapping");
        set_switch(2);if(held!==1)$fatal(1,"0.75 contrast mapping");
        set_switch(3);if(held!==3)$fatal(1,"1.25 contrast mapping");
        training=1;set_switch(4);
        if(held!==3 || live!==4)$fatal(1,"training demo hold/ADC live selection");
        training=0;repeat(3)@(negedge clk);
        if(held!==4)$fatal(1,"leaving demo training did not restore switch setting");
        set_switch(7);if(held!==2 || live!==2)$fatal(1,"invalid raw code fallback");
        set_switch(0);if(held!==2)$fatal(1,"zero switches must be neutral");
        set_switch(4);#2;rst_n=0;#1;
        if(held!==2 || live!==2)$fatal(1,"asynchronous reset neutral");
        $display("PASS tb_contrast_controls");$finish;
    end
    initial begin #100000;$fatal(1,"tb_contrast_controls TIMEOUT");end
endmodule
