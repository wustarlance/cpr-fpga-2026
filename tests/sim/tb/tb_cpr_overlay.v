`timescale 1ns/1ps
module tb_cpr_overlay;
 reg clk=0,rst=1,vs=1,de=0;
 reg[1:0]mode=0,rate=0,depth=0;
 reg[31:0]count=0;
 wire[23:0]rgb;
 always #5 clk=~clk;
 cpr_overlay dut(.clk(clk),.rst(rst),.vs(vs),.de(de),.rgb(24'h123456),
  .mode(mode),.count(count),.rate(rate),.depth_grade(depth),
  .pause_warning(1'b0),.rotate_due(1'b0),.beat(1'b0),
  .interval_ms(16'd545),.pause_ms(16'd0),.rotate_remaining_ms(32'd120000),
  .bpm(8'd110),.bpm_valid(1'b1),.sensor_fault(1'b0),
  .brightness_level(2'd3),.contrast_level(3'd2),.auto_running(1'b1),.out_rgb(rgb));
 integer x,y;
 task latch_frame;
  begin @(negedge clk);de=0;vs=1;@(negedge clk);vs=0;
   @(negedge clk);vs=1;end
 endtask
 task scan_to_rate_box;
  begin
   for(y=0;y<=96;y=y+1)begin
    for(x=0;x<640;x=x+1)begin
     @(negedge clk);de=1;#1;
     if(y==96 && x==627)begin
      if(rgb!==24'h20d060)$fatal(1,"rate box is not green for target grade: %h",rgb);
     end
    end
    @(negedge clk);de=0;@(negedge clk);
   end
  end
 endtask
 initial begin
  repeat(3)@(negedge clk);rst=0;
  mode=2;rate=2;depth=2;count=87;latch_frame;
  if(dut.frame_mode!=2 || dut.count_bcd!=16'h0087)$fatal(1,"frame snapshot/count rendering failed");
  count=123;rate=3;
  repeat(10)@(negedge clk);
  if(dut.count_bcd!=16'h0087 || dut.frame_rate!=2)$fatal(1,"status changed mid-frame");
  scan_to_rate_box;
  count=32'd10000;latch_frame;
  if(dut.count_bcd!=16'h9999 || dut.frame_rate!=3)$fatal(1,"next-frame snapshot/saturation failed");
  $display("PASS tb_cpr_overlay");$finish;
 end
 initial begin #2000000;$fatal(1,"TIMEOUT");end
endmodule
