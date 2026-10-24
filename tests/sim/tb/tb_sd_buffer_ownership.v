`timescale 1ns/1ps
module tb_sd_buffer_ownership;
 reg clk=0,mem_clk=0,rst_n=0,key_next=1,frame_start=0,write_toggle=0;
 wire valid,publish,done;
 wire[1:0]write_index,pending_index,active_index;
 integer loads=0,write_countdown=0,waits;
 always #5 clk=~clk;always #12.5 mem_clk=~mem_clk;
 wire sd_sec_ready,sd_sec_read_error,sd_init_done;
 wire [7:0] sd_sec_read_data;
 wire sd_sec_read_data_valid,sd_sec_read_end,sd_sec_read;
 wire [31:0] sd_sec_read_addr;
 wire sd_read_cancel,SD_nCS,SD_DCLK,SD_MOSI;
 sd_card_bmp #(.CLK_FREQ_HZ(1000),.SCALE_ENABLE(0)) dut(
  .clk(clk),.rst(!rst_n),.key_next(key_next),.key_prev(1'b1),
  .key_auto(1'b1),.external_auto(1'b0),
  .training_active(1'b0),.training_next(1'b0),.training_prev(1'b0),.page_status(),.state_code(),
  .bmp_width(16'd640),.bmp_height(16'd480),.display_valid(valid),
  .write_finish_toggle(write_toggle),.write_buf_idx(write_index),
  .disp_buf_idx(pending_index),.publish_req(publish),.publish_done(done),
  .write_req(),.write_req_ack(dut.write_req),.pixel_ready(1'b1),.write_en(),.write_data(),
  .sd_sec_ready(sd_sec_ready),.sd_sec_read_error(sd_sec_read_error),.sd_init_done(sd_init_done),
  .sd_sec_read_data(sd_sec_read_data),.sd_sec_read_data_valid(sd_sec_read_data_valid),
  .sd_sec_read_end(sd_sec_read_end),.sd_sec_read(sd_sec_read),
  .sd_sec_read_addr(sd_sec_read_addr),.sd_read_cancel(sd_read_cancel));

  // sd_card_top now lives at the top level and is shared with WAV playback,
  // so the bench supplies the sector model through the sd_sec_* slave port.
  sd_card_top #(.TOKEN_TIMEOUT_CYCLES(10000000),.SPI_TIMEOUT_CYCLES(1000000)) sd_card_top_m0(
   .clk(clk),.rst(!rst_n),.read_cancel(sd_read_cancel),
   .sd_sec_ready(sd_sec_ready),.sd_sec_read_error(sd_sec_read_error),
   .sd_init_done(sd_init_done),.sd_sec_read(sd_sec_read),
   .sd_sec_read_addr(sd_sec_read_addr),.sd_sec_read_data(sd_sec_read_data),
   .sd_sec_read_data_valid(sd_sec_read_data_valid),.sd_sec_read_end(sd_sec_read_end),
   .SD_nCS(SD_nCS),.SD_DCLK(SD_DCLK),.SD_MOSI(SD_MOSI),.SD_MISO(1'b1),
   .sd_sec_write(1'b0),.sd_sec_write_addr(32'd0),.sd_sec_write_data(8'd0),
   .sd_sec_write_data_req(),.sd_sec_write_end());
 frame_buffer_publish swap(clk,rst_n,publish,pending_index,,done,
                           mem_clk,rst_n,frame_start,active_index);
 always @(posedge clk)begin
  if(rst_n && dut.load_start_pulse)begin
   loads=loads+1;
   if(valid && write_index==active_index)$fatal(1,"writer reused active read buffer");
   write_countdown=100; // writer finishes before the source model returns ready
  end else if(write_countdown!=0)begin
   write_countdown=write_countdown-1;
   if(write_countdown==0)write_toggle=~write_toggle;
  end
  #1;
  if(rst_n && publish && !dut.bmp_ready)$fatal(1,"published before source finished");
 end
 task press_next;
  begin @(negedge clk);key_next=0;repeat(30)@(negedge clk);
   key_next=1;repeat(30)@(negedge clk);end
 endtask
 task adopt_frame;
  begin @(negedge mem_clk);frame_start=1;@(negedge mem_clk);frame_start=0;
   repeat(15)@(negedge clk);end
 endtask
 task wait_publication;
  begin waits=0;while(!dut.publish_wait)begin @(negedge clk);waits=waits+1;
   if(waits>1000)$fatal(1,"publication timeout");end
   repeat(20)@(negedge clk);end
 endtask
 initial begin
  repeat(5)@(negedge clk);rst_n=1;
  while(loads<1)@(negedge clk);
  press_next;wait_publication;
  if(valid || loads!=1)$fatal(1,"initial frame committed without read confirmation");
  adopt_frame;
  while(loads<2)@(negedge clk);
  press_next;wait_publication;
  repeat(60)@(negedge clk);
  if(loads!=2 || active_index!=0 || !dut.load_busy)$fatal(1,"old buffer released before frame boundary");
  adopt_frame;
  while(loads<3)@(negedge clk);
  if(write_index!=0 || active_index!=1)$fatal(1,"queued load did not use released buffer");
  $display("PASS tb_sd_buffer_ownership");$finish;
 end
 initial begin #100000;$fatal(1,"TIMEOUT");end
endmodule
