`timescale 1ns/1ps
module tb_reset_release;
    reg clk=0,reset_n=0;
    wire released;
    always #5 clk=~clk;
    reset_release dut(clk,reset_n,released,1'b1);
    initial begin
        #2;reset_n=1;#1;reset_n=0;#1;
        if(released!==0)$fatal(1,"reset assertion must be asynchronous");
        #3;reset_n=1;
        repeat(3) begin @(posedge clk);#1;if(released!==0)$fatal(1,"released before readiness and release synchronizers settled"); end
        @(posedge clk);#1;if(released!==1)$fatal(1,"did not release synchronously");
        #2;reset_n=0;#1;if(released!==0)$fatal(1,"did not asynchronously reassert");
        #1;reset_n=1;
        repeat(3) begin @(posedge clk);#1;if(released!==0)$fatal(1,"early release after reset"); end
        @(posedge clk);#1;if(released!==1)$fatal(1,"reset recovery failed");
        $display("PASS tb_reset_release");$finish;
    end
endmodule
