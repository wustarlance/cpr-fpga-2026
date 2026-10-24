`timescale 1ns/1ps
// Behavioral ODDR model only: checks serialization and lane alignment,
// not electrical swing, differential skew, eye opening or PLL jitter.
module EG_LOGIC_ODDR(input clk,rst,d0,d1,output reg q);
    // Per installed sim_release/eg4/eg_logic_io.v: both data inputs are
    // captured at the rising edge; the retained d1 is emitted at falling.
    reg next_falling;
    always @(posedge clk or posedge rst)
        if(rst) begin q<=0;next_falling<=0;end
        else begin q<=d0;next_falling<=d1;end
    always @(negedge clk or posedge rst)
        if(rst) q<=0; else q<=$test$plusargs("BAD_ODDR")?d1:next_falling;
endmodule

module tb_hdmi_lane_timing;
    reg pixel=0,serial=0,rst=1;
    reg [9:0] d0=10'h2c6,d1=10'h139,d2=10'h35a;
    wire c0,c1,c2,cc;
    reg [9:0] got0=0,got1=0,got2=0,gotc=0;
    integer i, offset, common_matches, round;
    reg [9:0] wantc=10'b1111100000;
    always #20 pixel=~pixel;
    always #4 serial=~serial;
    hdmi_phy_wrapper dut(.I_pixel_clk(pixel),.I_serial_clk(serial),.I_rst(rst),
      .I_tmds_channel_0(d0),.I_tmds_channel_1(d1),.I_tmds_channel_2(d2),.I_tmds_channel_clk(wantc),
      .O_tmds_ch0_p(c0),.O_tmds_ch1_p(c1),.O_tmds_ch2_p(c2),.O_tmds_clk_p(cc));
    function [9:0] rotate;
      input [9:0] value; input integer amount;
      begin rotate=(value>>amount)|(value<<(10-amount));end
    endfunction
    task check_word;
      begin
        // Sample a whole character after the common serializer pipeline fills.
        repeat(12) @(negedge pixel);
        for(i=0;i<10;i=i+1) begin
          @(serial); #0.001;
          got0[i]=c0;got1[i]=c1;got2[i]=c2;gotc[i]=cc;
        end
        common_matches=0;
        for(offset=0;offset<10;offset=offset+1)
          if(got0===rotate(d0,offset) && got1===rotate(d1,offset) &&
             got2===rotate(d2,offset) && gotc===rotate(wantc,offset)) common_matches=common_matches+1;
        if(common_matches!=1) $fatal(1,"HDMI lanes lost common character alignment: %h %h %h %h",got0,got1,got2,gotc);
      end
    endtask
    initial begin
      repeat(4) @(negedge pixel);rst=0;
      for(round=0;round<8;round=round+1) begin
        check_word;
        @(negedge pixel);
        d0=d0+10'h035;d1=d1^10'h1a3;d2=d2+10'h061;
      end
      $display("PASS: tb_hdmi_lane_timing pixel=25MHz serial=125MHz UI=4ns");$finish;
    end
    initial begin #20000;$fatal(1,"HDMI timing timeout");end
endmodule
