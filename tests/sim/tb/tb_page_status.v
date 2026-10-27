`timescale 1ns/1ps
module tb_page_status;
reg src_clk=0,clk=0,rst_n=0,vs=1,de=0;
reg [11:0] status=0;
wire [11:0] video_status;
wire [23:0] rgb;
reg [11:0] accepted[0:1023];
integer a=0,i,j,found,frames=0;
always #5 src_clk=~src_clk;
always #20 clk=~clk;
page_status_cdc transfer(src_clk,rst_n,status,clk,rst_n,video_status);
cpr_overlay #(.PAGE_STATUS_ENABLE(1)) overlay(
 .clk(clk),.rst(!rst_n),.vs(vs),.de(de),.rgb(24'h123456),.mode(2'd2),
 .count(32'd0),.rate(2'd0),.depth_grade(2'd0),.interval_ms(16'd0),.pause_ms(16'd0),
 .rotate_remaining_ms(32'd0),.bpm(8'd0),.bpm_valid(1'b0),.sensor_fault(1'b0),
 .brightness_level(2'd3),.contrast_level(3'd2),.auto_running(1'b0),
 .pause_warning(1'b0),.rotate_due(1'b0),.beat(1'b0),.page_status(video_status),
 .subtitle_en(1'b1),.out_rgb(rgb));
always @(posedge src_clk)if(rst_n&&transfer.send)begin
 accepted[a]=status;a=a+1;
end
always @(negedge clk)if(rst_n&&transfer.u_transfer.dst_valid)begin
 found=0;
 for(j=0;j<a;j=j+1)if(video_status===accepted[j])found=1;
 if(!found)$fatal(1,"torn or invented coherent status %h",video_status);
end
task tick;begin @(negedge clk);end endtask
task settle;
 input [11:0] value;
 begin status=value;repeat(20)tick;if(video_status!==value)$fatal(1,"latest status lost");end
endtask
task frame;
 begin vs=1;tick;vs=0;tick;vs=1;tick;frames=frames+1;end
endtask
task header;
 input [7:0] prefix,page,total,state;
 begin
  // Inspect the selected header character at actual scan positions.
  force overlay.y=0;
  force overlay.x=176;#1;if(overlay.character!==prefix)$fatal(1,"page prefix");
  force overlay.x=192;#1;if(overlay.character!==page)$fatal(1,"page digit");
  force overlay.x=224;#1;if(overlay.character!==total)$fatal(1,"page count");
  force overlay.x=240;#1;if(overlay.character!==state)$fatal(1,"page state %c",overlay.character);
  release overlay.x;release overlay.y;
 end
endtask
initial begin
 repeat(4)tick;rst_n=1;
 for(i=0;i<170;i=i+1)begin @(negedge src_clk);status=(i*53)^12'ha96;end
 settle({1'b1,2'd0,3'd4,2'd1,1'b1,1'b0,1'b0,1'b1});
 frame;header("T","2","4","L");
 // In-frame updates do not tear the header; the next VS adopts the word.
 settle({1'b1,2'd0,3'd1,2'd1,1'b0,1'b1,1'b0,1'b1});
 header("T","2","4","L");frame;header("T","2","1","M");
 settle({1'b1,2'd3,3'd4,2'd1,1'b0,1'b0,1'b1,1'b0});
 frame;header("P","4","4","E");
 // Pixel checker for glyph '4', at x192..201, y0..13, using an independent bitmap.
 force overlay.y=0;force overlay.x=194;de=1;#1;
 if(rgb!==24'h805020)$fatal(1,"glyph blank pixel changed");
 force overlay.x=198;#1;
 if(rgb!==24'hffffff)$fatal(1,"glyph lit pixel missing");
 // Page status must not cover tutorial content in the left region.
 force overlay.y=120;force overlay.x=100;#1;
 if(rgb!==24'h123456)$fatal(1,"page indicator covered tutorial");
 release overlay.x;release overlay.y;de=0;
 settle(0);frame;header("P","-","0"," ");
 rst_n=0;repeat(3)tick;rst_n=1;settle(12'h9a5);
 if(transfer.u_transfer.overflow_sticky)$fatal(1,"status producer overflowed mailbox");
 $display("PASS: tb_page_status coherent transfers=%0d frames=%0d",a,frames);$finish;
end
initial begin #200000;$fatal(1,"TIMEOUT page status");end
endmodule
