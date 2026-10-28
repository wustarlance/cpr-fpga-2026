`timescale 1ns/1ps
module tb_sd_scaled_pages;
 reg foreign_busy=0;
 reg training=0,train_next=0,train_prev=0,hold_publish=0,auto_run=0;
 wire [11:0] page_status;
 defparam sd_card_top_m0.PAGE_COLOR=1;

 reg clk=0,mem_clk=0,rst_n=0,key_next=1;
 reg hold_ack=0,hold_finish=0,frozen_toggle=0;
 wire display_valid,publish,done,write_req,write_en,writer_ack,writer_finish;
 wire publish_fade;
 reg expect_auto_tag=0;
 integer tagged_publications=0;
 wire[1:0]write_index,pending_index,active_index;
 wire[31:0]write_data;
 wire[3:0]state_code;
 wire[2:0]media_error;
 wire fifo_reset,app_write;
 wire[20:0]app_address;
 reg[31:0]fifo[0:511],memory[0:255];
 integer wp=0,rp=0,j,loads=0,publications=0,frame_counter=0;
 integer test_case,w,base_loads,b,c,p,offset;
 wire[9:0]used=wp-rp;
 reg frame_start=0,write_toggle=0;
 wire[31:0]fifo_word=fifo[rp%512];
 always #5 clk=~clk;
 always #12.5 mem_clk=~mem_clk;
 wire sd_sec_ready,sd_sec_read_error,sd_init_done;
 wire [7:0] sd_sec_read_data;
 wire sd_sec_read_data_valid,sd_sec_read_end,sd_sec_read;
 wire [31:0] sd_sec_read_addr;
 wire sd_read_cancel,SD_nCS,SD_DCLK,SD_MOSI;
 sd_card_bmp #(.CLK_FREQ_HZ(1000),.SCALE_ENABLE(1),.DST_WIDTH(8),.DST_HEIGHT(4),.READER_TIMEOUT_CYCLES(80),
  .LOAD_TIMEOUT_CYCLES(5000),.SCAN_MAX_SECTOR(3),.SCAN_TARGET_COUNT(4)) dut(
  .clk(clk),.rst(!rst_n),.key_next(key_next),.key_prev(1'b1),
  .key_auto(1'b1),.external_auto(auto_run),
  .training_active(training),.training_next(train_next),.training_prev(train_prev),.page_status(page_status),.state_code(state_code),.media_error(media_error),
  .bmp_width(16'd4),.bmp_height(16'd2),.display_valid(display_valid),
  .write_finish_toggle(hold_finish?frozen_toggle:write_toggle),
  .write_buf_idx(write_index),.disp_buf_idx(pending_index),
  .publish_req(publish),.publish_fade(publish_fade),.publish_done(done),.write_req(write_req),
  .write_req_ack(writer_ack&&!hold_ack),.pixel_ready(1'b1),.write_en(write_en),.write_data(write_data),
  .sd_sec_ready(sd_sec_ready && !foreign_busy),.sd_sec_read_error(sd_sec_read_error),.sd_init_done(sd_init_done),
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
 frame_fifo_write #(.BURST_SIZE(4),.FRAME_WIDTH(8),.FRAME_HEIGHT(4)) writer(
  .rst(!rst_n),.mem_clk(mem_clk),.Sdr_init_done(rst_n),.Sdr_init_ref_vld(1'b0),
  .Sdr_busy(1'b0),.App_rd_busy(1'b0),.O_wr_busy(),
  .App_wr_en(app_write),.App_wr_addr(app_address),
  .write_req(write_req),.write_req_ack(writer_ack),.write_finish(writer_finish),
  .write_addr_0(21'd0),.write_addr_1(21'd64),.write_addr_2(21'd128),.write_addr_3(21'd192),
  .write_addr_index(write_index),.write_len(21'd32),.fifo_aclr(fifo_reset),.rdusedw(used));
 // Behavioural dual-clock FIFO: reset/discard and word order are checked here;
 // this is not a timing model of the encrypted vendor FIFO or SDRAM.
 always @(posedge clk or posedge fifo_reset or negedge rst_n)begin
  if(!rst_n||fifo_reset)wp<=0;
  else if(write_en)begin fifo[wp%512]<=write_data;wp<=wp+1;end
 end
 always @(posedge mem_clk or posedge fifo_reset or negedge rst_n)begin
  if(!rst_n||fifo_reset)rp<=0;
  else if(app_write)rp<=rp+1;
 end
 always @(posedge mem_clk)begin
  if(!rst_n)begin frame_counter<=0;frame_start<=0;write_toggle<=0;end
  else begin
   frame_counter<=frame_counter+1;frame_start<=!hold_publish&&(frame_counter%30)==0;
   if(writer_finish)write_toggle<=~write_toggle;
   if(app_write)begin
    if(used==0)$fatal(1,"memory writer consumed an empty FIFO");
    if(display_valid&&app_address/64==active_index)$fatal(1,"active display buffer overwritten");
    if(app_address>255)$fatal(1,"write outside owned frame buffers");
    memory[app_address]<=fifo_word;
   end
  end
 end
 always @(posedge clk)begin
  if(!rst_n)begin loads<=0;publications<=0;end
  else begin
   if(dut.load_start_pulse)loads<=loads+1;
   if(publish)begin
    publications<=publications+1;
    if(publish_fade!==expect_auto_tag)$fatal(1,"publication fade tag is wrong case=%0d tag=%b expected=%b",test_case,publish_fade,expect_auto_tag);
    if(publish_fade)tagged_publications=tagged_publications+1;
    if(!dut.cache_valid[pending_index])$fatal(1,"bad/partial cache slot published");
   end
  end
 end

 initial if($test$plusargs("admission_busy")) begin
  wait(rst_n);
  wait(dut.scan_done && dut.g_cache_scheduler.select_load_q &&
       dut.g_cache_scheduler.sd_admit_ready_q && !dut.load_busy && !dut.recovering);
  @(negedge clk);foreign_busy=1;
  repeat(3)@(negedge clk);
  if(!dut.load_busy)$fatal(1,"registered admission did not accept the pending job");
  repeat(29)begin @(negedge clk);
   if(sd_sec_read)$fatal(1,"sector command issued while current bus ready was low");
  end
  foreign_busy=0;
  $display("INFO admitted job waited for live sector ready");
 end
 task tick;begin @(negedge clk);end endtask
 task press;
  begin key_next=0;repeat(30)tick;key_next=1;repeat(30)tick;end
 endtask
 task wait_image;
  input integer index;
  integer x,y,sx,sy,n;
  begin
   w=0;while(!display_valid||dut.img_idx!=index||dut.page_pending||dut.publish_wait)begin
    tick;w=w+1;if(w>30000)$fatal(1,"scaled page never adopted case=%0d target=%0d actual=%0d cache=%b failed=%b error=%0d loads=%0d",test_case,index,dut.img_idx,dut.cache_valid,dut.cache_failed,media_error,loads);
   end
   if(active_index!=index)$fatal(1,"image number and immutable slot disagree");
   for(y=0;y<4;y=y+1)for(x=0;x<8;x=x+1)begin
    sx=x/2;sy=(3-y)/2;n=sy*4+sx;
    b=(32+index*48)+n*3;c=b+1;j=b+2;
    if(memory[index*64+y*8+x]!=={j[7:0],c[7:0],b[7:0],8'd0})
     $fatal(1,"scaled page %0d contains stale/missing pixel (%0d,%0d)",index,x,y);
   end
  end
 endtask
 task wait_cache;
  input [3:0]mask;
  begin w=0;while((dut.cache_valid&mask)!=mask)begin
   tick;w=w+1;if(w>40000)$fatal(1,"cache incomplete case=%0d cache=%b failed=%b loads=%0d",test_case,dut.cache_valid,dut.cache_failed,loads);
  end repeat(20)tick;end
 endtask
 task boot;
  input integer pictures,in_training;
  begin
   rst_n=0;training=in_training;train_next=0;train_prev=0;key_next=1;
   hold_ack=0;hold_finish=0;hold_publish=0;auto_run=0;
   sd_card_top_m0.image_count=pictures;
   sd_card_top_m0.fail_budget=0;sd_card_top_m0.fault_kind=0;
   sd_card_top_m0.fail_sector=1;sd_card_top_m0.only_transaction=0;
   for(j=0;j<256;j=j+1)memory[j]=32'hbadc0ffe;
   repeat(5)tick;rst_n=1;
  end
 endtask
 task nav;
  input integer previous;
  begin train_next=!previous;train_prev=previous;repeat(6)tick;
   train_next=0;train_prev=0;repeat(6)tick;end
 endtask
 task enter;begin training=1;repeat(8)tick;end endtask
 task leave;begin training=0;repeat(8)tick;end endtask
 initial begin
  test_case=1;boot(4,0);wait_image(0);wait_cache(15);
  if(loads!=4)$fatal(1,"initial cache did not load each slot exactly once");
  press;wait_image(1);press;wait_image(2);
  enter;wait_image(1);
  if(dut.u_pages.saved_index!=2)$fatal(1,"training entry failed to save browsing page");
  nav(0);wait_image(2);nav(1);wait_image(1);nav(1);wait_image(0);nav(1);wait_image(3);
  leave;wait_image(2);
  if(loads!=4)$fatal(1,"cached training navigation reread SD");
  $display("CHECK cached training entry, wrap, restoration and scaled pixels");

  test_case=2;hold_publish=1;enter;w=0;
  while(!dut.publish_wait)begin tick;w=w+1;if(w>1000)$fatal(1,"cached training request never published");end
  base_loads=loads;nav(0);nav(0);nav(0);leave;
  if(dut.page_index!=2)$fatal(1,"exit did not supersede rapid queued training requests");
  repeat(100)tick;
  if(loads!=base_loads||dut.img_idx!=2)$fatal(1,"publication mutated cached image before frame boundary");
  hold_publish=0;wait_image(2);
  if(loads!=base_loads)$fatal(1,"cached queued request caused reread");
  $display("CHECK cached publication ownership and latest exit target");

  test_case=3;boot(4,0);
  // Enable a persistent target fault only after catalogue scan, leaving the
  // source list intact. Slot zero remains a good visible frame throughout.
  wait(dut.scan_done);sd_card_top_m0.fault_kind=3;sd_card_top_m0.fail_budget=-1;
  wait_image(0);wait(dut.cache_failed[1]);wait_cache(4'b1101);
  if(dut.cache_valid[1]||dut.img_idx!=0)$fatal(1,"failed preload was made visible");
  base_loads=loads;repeat(500)tick;
  if(loads!=base_loads)$fatal(1,"failed preload retried forever");
  sd_card_top_m0.fail_budget=0;enter;wait_image(1);wait_cache(15);
  if(loads!=base_loads+1)$fatal(1,"explicit training action did not recover exactly once");
  leave;wait_image(0);
  $display("CHECK stalled source, bounded retry and manual recovery");

  test_case=4;boot(1,0);wait_image(0);base_loads=loads;
  enter;repeat(100)tick;
  if(!dut.page_missing||state_code!=4'hd||dut.img_idx!=0||loads!=base_loads)
   $fatal(1,"missing training page substituted or loaded");
  nav(0);wait_image(0);leave;wait_image(0);
  test_case=5;boot(4,1);wait_image(1);
  if(publications!=1)$fatal(1,"boot training flashed an unrelated browsing image");
  wait_cache(15);leave;wait_image(0);
  test_case=6;boot(0,1);repeat(4000)tick;
  if(!dut.page_missing||loads!=0||display_valid)$fatal(1,"empty catalogue loaded a page");
  test_case=7;boot(4,0);wait_image(0);wait_cache(15);
  expect_auto_tag=1;auto_run=1;wait_image(1);
  auto_run=0;repeat(12)tick;expect_auto_tag=0;
  if(tagged_publications!=1)$fatal(1,"automatic next page did not get one fade tag");
  press;wait_image(2);
  // A one-image catalogue must not fade to the same image on each timer.
  test_case=8;boot(1,0);wait_image(0);auto_run=1;
  w=0;while(publications<2)begin tick;w=w+1;if(w>3000)$fatal(1,"single-page auto timer");end
  auto_run=0;repeat(100)tick;
  $display("PASS: tb_sd_scaled_pages: scaled four-slot pixels, cached training policy, recovery, missing pages and boot request");$finish;
 end
 initial begin #4000000;$fatal(1,"TIMEOUT scaled training pages");end
endmodule
