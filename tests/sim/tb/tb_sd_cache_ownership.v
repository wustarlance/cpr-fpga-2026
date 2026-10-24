`timescale 1ns/1ps
module tb_sd_cache_ownership;
 reg clk=0,mem_clk=0,rst_n=0,key_next=1,key_prev=1,auto_enable=0;
 reg frame_start=0,write_toggle=0;
 wire valid,publish,done;
 wire[1:0]write_index,pending_index,active_index;
 integer loads=0,write_countdown=0,waits,cycle=0;
 always #5 clk=~clk;always #12.5 mem_clk=~mem_clk;
 wire sd_sec_ready,sd_sec_read_error,sd_init_done;
 wire [7:0] sd_sec_read_data;
 wire sd_sec_read_data_valid,sd_sec_read_end,sd_sec_read;
 wire [31:0] sd_sec_read_addr;
 wire sd_read_cancel,SD_nCS,SD_DCLK,SD_MOSI;
 sd_card_bmp #(.CLK_FREQ_HZ(1000),.SCALE_ENABLE(1)) dut(
  .clk(clk),.rst(!rst_n),.key_next(key_next),.key_prev(key_prev),
  .key_auto(1'b1),.external_auto(auto_enable),.training_active(1'b0),.training_next(1'b0),.training_prev(1'b0),.page_status(),.state_code(),
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
  cycle=cycle+1;
  if(rst_n && dut.load_start_pulse)begin
   if(loads>=4 || write_index!==loads[1:0])$fatal(1,"slot loaded twice or out of order");
   if(dut.load_sector!==(loads+1)*100)$fatal(1,"wrong catalogue sector");
   loads=loads+1;
   // First completion is early, second is late. Neither condition alone
   // may mark the cache valid or publish a frame.
   write_countdown=(loads==2)?700:100;
  end else if(write_countdown!=0)begin
   write_countdown=write_countdown-1;
   if(write_countdown==0)write_toggle=~write_toggle;
  end
  if(rst_n && publish && !dut.cache_valid[pending_index])
   $fatal(1,"published a partial cache slot");
 end
 task press;
  input previous;
  begin @(negedge clk);if(previous)key_prev=0;else key_next=0;
   repeat(30)@(negedge clk);key_next=1;key_prev=1;repeat(30)@(negedge clk);end
 endtask
 task adopt_frame;
  begin @(negedge mem_clk);frame_start=1;@(negedge mem_clk);frame_start=0;
   repeat(15)@(negedge clk);end
 endtask
 task wait_publication;
  begin waits=0;while(!dut.publish_wait)begin @(negedge clk);waits=waits+1;
   if(waits>4000)$fatal(1,"publication timeout");end
   repeat(20)@(negedge clk);end
 endtask
 task switch_to;
  input previous; input [1:0] expected;
  reg [1:0] old_index;
  begin
   old_index=active_index;press(previous);wait_publication;
   if(active_index!==old_index)$fatal(1,"index changed outside frame boundary");
   adopt_frame;
   if(active_index!==expected || dut.img_idx!==expected)$fatal(1,"wrong committed index");
   if(loads!=4)$fatal(1,"cached switch reread SD");
  end
 endtask
 initial begin
  repeat(5)@(negedge clk);rst_n=1;
  wait_publication;
  if(valid)$fatal(1,"first frame visible before reader ACK");
  adopt_frame;
  if(!valid || active_index!=0)$fatal(1,"first slot was not displayed");
  // Request slot 1 during its background load. It must be retained until
  // BOTH the source and delayed memory completion have arrived.
  press(0);wait_publication;
  if(!dut.cache_valid[1])$fatal(1,"pending target not fully cached");
  adopt_frame;
  if(active_index!=1)$fatal(1,"queued uncached request lost");
  wait(dut.cache_valid==4'b1111);
  repeat(1000)@(negedge clk);
  if(loads!=4 || dut.load_seq!=4)$fatal(1,"preload counter wrapped");
  switch_to(0,2);switch_to(0,3);switch_to(0,0);switch_to(1,3);
  auto_enable=1;wait_publication;adopt_frame;
  if(active_index!=0 || loads!=4)$fatal(1,"cached auto rotation failed");
  auto_enable=0;
  $display("PASS tb_sd_cache_ownership: four immutable slots, early first frame, deferred requests, cached switching");$finish;
 end
 initial begin #200000;$fatal(1,"TIMEOUT");end
endmodule
