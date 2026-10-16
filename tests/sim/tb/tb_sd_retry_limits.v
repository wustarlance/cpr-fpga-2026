`timescale 1ns/1ps
module tb_sd_retry_limits;
 reg clk=0,rst=1;
 wire[2:0]failed;
 integer n;
 always #5 clk=~clk;
 genvar k;
 generate for(k=0;k<3;k=k+1)begin:cases
  localparam LIMIT=k==0?0:k==1?2:255;
  localparam EXPECTED=k==1?3:1;
  wire[3:0]status;
  wire published,valid;
  integer attempts=0;
  sd_card_bmp #(.CLK_FREQ_HZ(1000),.SCALE_ENABLE(0),.RETRY_LIMIT(LIMIT),
    .LOAD_TIMEOUT_CYCLES(100),.READER_TIMEOUT_CYCLES(80),
    .SCAN_MAX_SECTOR(0),.SCAN_TARGET_COUNT(1)) dut(
   .clk(clk),.rst(rst),.key_next(1'b1),.key_prev(1'b1),.key_auto(1'b1),.external_auto(1'b0),
  .training_active(1'b0),.training_next(1'b0),.training_prev(1'b0),.page_status(),
   .state_code(status),.media_error(),.bmp_width(16'd4),.bmp_height(16'd2),
   .display_valid(valid),.write_finish_toggle(1'b0),.write_buf_idx(),.disp_buf_idx(),
   .publish_req(published),.publish_done(1'b0),.write_req(),.write_req_ack(1'b0),
   .pixel_ready(1'b1),.write_en(),.write_data(),.SD_nCS(),.SD_DCLK(),.SD_MOSI(),.SD_MISO(1'b1));
  assign failed[k]=dut.media_fault;
  always @(posedge clk)if(!rst)begin
   if(dut.load_start_pulse)attempts<=attempts+1;
   if(published||valid)$fatal(1,"incomplete first image published");
  end
  always @(negedge clk)if(!rst&&dut.media_fault)
   if(attempts!=EXPECTED||status!=4'he)$fatal(1,"retry limit %0d produced %0d attempts",LIMIT,attempts);
 end endgenerate
 initial begin
  repeat(5)@(negedge clk);rst=0;n=0;
  while(failed!=3'b111)begin @(negedge clk);n=n+1;if(n>3000)$fatal(1,"retry limits never terminated");end
  repeat(200)@(negedge clk);
  $display("PASS: tb_sd_retry_limits");$finish;
 end
 initial begin #50000;$fatal(1,"TIMEOUT retry limits");end
endmodule
