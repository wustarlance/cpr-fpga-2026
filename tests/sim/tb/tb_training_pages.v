`timescale 1ns/1ps
module tb_training_pages;
 reg training=0,train_next=0,train_prev=0,hold_publish=0,auto_run=0;
 wire [11:0] page_status;
 defparam dut.sd_card_top_m0.PAGE_COLOR=1;

 reg clk=0,mem_clk=0,rst_n=0,key_next=1;
 reg hold_ack=0,hold_finish=0,frozen_toggle=0;
 wire display_valid,publish,done,write_req,write_en,writer_ack,writer_finish;
 wire[1:0]write_index,pending_index,active_index;
 wire[31:0]write_data;
 wire[3:0]state_code;
 wire[2:0]media_error;
 wire fifo_reset,app_write;
 wire[20:0]app_address;
 reg[31:0]fifo[0:511],memory[0:127];
 integer wp=0,rp=0,j,loads=0,publications=0,frame_counter=0;
 integer test_case,w,base_loads,b,c,p,offset;
 wire[9:0]used=wp-rp;
 reg frame_start=0,write_toggle=0;
 wire[31:0]fifo_word=fifo[rp%512];
 always #5 clk=~clk;
 always #12.5 mem_clk=~mem_clk;
 sd_card_bmp #(.CLK_FREQ_HZ(1000),.READER_TIMEOUT_CYCLES(80),
  .LOAD_TIMEOUT_CYCLES(2500),.SCAN_MAX_SECTOR(3),.SCAN_TARGET_COUNT(4)) dut(
  .clk(clk),.rst(!rst_n),.key_next(key_next),.key_prev(1'b1),
  .key_auto(1'b1),.external_auto(auto_run),
  .training_active(training),.training_next(train_next),.training_prev(train_prev),.page_status(page_status),.state_code(state_code),.media_error(media_error),
  .bmp_width(16'd4),.bmp_height(16'd2),.display_valid(display_valid),
  .write_finish_toggle(hold_finish?frozen_toggle:write_toggle),
  .write_buf_idx(write_index),.disp_buf_idx(pending_index),
  .publish_req(publish),.publish_done(done),.write_req(write_req),
  .write_req_ack(writer_ack&&!hold_ack),.write_en(write_en),.write_data(write_data),
  .SD_nCS(),.SD_DCLK(),.SD_MOSI(),.SD_MISO(1'b1));
 frame_buffer_publish swap(clk,rst_n,publish,pending_index,,done,
                           mem_clk,rst_n,frame_start,active_index);
 frame_fifo_write #(.BURST_SIZE(4),.FRAME_WIDTH(4),.FRAME_HEIGHT(2)) writer(
  .rst(!rst_n),.mem_clk(mem_clk),.Sdr_init_done(rst_n),.Sdr_init_ref_vld(1'b0),
  .Sdr_busy(1'b0),.App_rd_busy(1'b0),.O_wr_busy(),
  .App_wr_en(app_write),.App_wr_addr(app_address),
  .write_req(write_req),.write_req_ack(writer_ack),.write_finish(writer_finish),
  .write_addr_0(21'd0),.write_addr_1(21'd64),.write_addr_2(21'd0),.write_addr_3(21'd0),
  .write_addr_index(write_index),.write_len(21'd8),.fifo_aclr(fifo_reset),.rdusedw(used));
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
    if(app_address>127)$fatal(1,"write outside owned frame buffers");
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
    if(dut.operation_error||dut.recovering)$fatal(1,"bad/aborted frame published");
   end
  end
 end
 task tick;begin @(negedge clk);end endtask
 task press;
  begin key_next=0;repeat(30)tick;key_next=1;repeat(30)tick;end
 endtask
 task wait_image;
  input integer index;
  begin
   w=0;while(!display_valid||dut.img_idx!=index||dut.load_busy||dut.page_pending||dut.recovering)begin
    tick;w=w+1;if(w>15000)$fatal(1,"image never adopted case=%0d error=%0d loads=%0d state=%h",test_case,media_error,loads,state_code);
   end
   // Check all real writer addresses and all eight RGB values after adoption.
   offset=active_index*64;
   for(p=0;p<8;p=p+1)begin
    b=(32+index*48)+p*3;c=b+1;j=b+2;
    if(memory[offset+(1-p/4)*4+p%4]!=={j[7:0],c[7:0],b[7:0],8'd0})
     $fatal(1,"recovered image contains stale/missing pixel %0d",p);
   end
  end
 endtask

 task boot;
  input integer pictures,in_training;
  begin
   rst_n=0;training=in_training;train_next=0;train_prev=0;key_next=1;
   hold_ack=0;hold_finish=0;hold_publish=0;auto_run=0;
   dut.sd_card_top_m0.image_count=pictures;
   dut.sd_card_top_m0.fail_budget=0;dut.sd_card_top_m0.fault_kind=0;
   dut.sd_card_top_m0.fail_sector=1;dut.sd_card_top_m0.only_transaction=0;
   repeat(5)tick;rst_n=1;
  end
 endtask
 task nav;
  input integer previous;
  begin
   train_next=!previous;train_prev=previous;repeat(6)tick;
   train_next=0;train_prev=0;repeat(6)tick;
  end
 endtask
 task enter;
  begin training=1;repeat(8)tick;end
 endtask
 task leave;
  begin training=0;repeat(8)tick;end
 endtask
 task wait_fault;
  begin
   w=0;while(!dut.media_fault)begin tick;w=w+1;if(w>15000)$fatal(1,"training failure never bounded");end
  end
 endtask
 initial begin
  test_case=1;boot(4,0);wait_image(0);
  press;wait_image(1);press;wait_image(2);press;wait_image(3);
  enter;wait_image(1);
  if(dut.u_pages.saved_index!=3)$fatal(1,"entry did not save visible browsing page");
  nav(0);wait_image(2);nav(1);wait_image(1);nav(1);wait_image(0);nav(1);wait_image(3);
  leave;wait_image(3);
  $display("CHECK entry, forward/backward wrap and browsing restoration");
  test_case=2;boot(4,0);wait_image(0);press;wait_image(1);press;wait_image(2);
  hold_publish=1;enter;w=0;
  while(!dut.publish_wait)begin tick;w=w+1;if(w>5000)$fatal(1,"training load never reached publication");end
  if(active_index!=dut.disp_buf_idx && dut.img_idx!=2)$fatal(1,"old browsing image lost");
  base_loads=loads;nav(0);nav(0);nav(0); // latest training target zero
  if(dut.page_index!=0)$fatal(1,"queued navigation lost latest target");
  leave; // restore page two must replace the queued training target zero
  if(dut.page_index!=2)$fatal(1,"restore did not supersede pending training target");
  repeat(120)tick;
  if(loads!=base_loads||dut.img_idx!=2)$fatal(1,"in-flight publication was cancelled or reused");
  hold_publish=0;wait_image(2);
  if(loads!=base_loads+1)$fatal(1,"obsolete queued page loaded after exit");
  $display("CHECK rapid navigation, irrevocable publication and exit priority");
  test_case=3;boot(4,0);wait_image(0);
  dut.sd_card_top_m0.fault_kind=1;dut.sd_card_top_m0.fail_budget=-1;
  enter;wait_fault;base_loads=loads;repeat(500)tick;
  if(loads!=base_loads||dut.img_idx!=0||!display_valid)$fatal(1,"failed training page retried forever or changed display");
  nav(0);wait_image(2);leave;wait_image(0);
  $display("CHECK failed default retains old page, next key recovers and exit restores");
  test_case=4;boot(1,0);wait_image(0);base_loads=loads;
  enter;repeat(100)tick;
  if(!dut.page_missing||state_code!=4'hd||dut.img_idx!=0||loads!=base_loads)
   $fatal(1,"missing training page silently substituted");
  nav(0);wait_image(0);leave;wait_image(0);
  $display("CHECK one-page catalog reports missing default without substitution");
  test_case=5;boot(4,1);wait_image(1);
  if(loads!=1||publications!=1)$fatal(1,"boot training flashed an unrelated first page");
  leave;wait_image(0);
  $display("CHECK pre-scan training request and no-saved-page fallback");
  test_case=6;boot(4,0);wait_image(0);auto_run=1;repeat(990)tick;
  enter;auto_run=0;wait_image(1);base_loads=loads;repeat(2200)tick;
  if(loads!=base_loads||dut.img_idx!=1)$fatal(1,"autoplay leaked into training");
  leave;wait_image(0);
  // Failed scan can be restarted by an explicit training action.
  test_case=7;boot(4,0);
  dut.sd_card_top_m0.fail_sector=0;dut.sd_card_top_m0.fault_kind=1;dut.sd_card_top_m0.fail_budget=-1;
  wait_fault;dut.sd_card_top_m0.fail_budget=0;enter;wait_image(1);leave;wait_image(0);
  $display("CHECK autoplay suppression and failed-scan manual recovery");
  test_case=8;boot(0,1);repeat(3000)tick;
  if(!dut.page_missing||loads!=0||display_valid)$fatal(1,"empty catalog loaded a page");
  nav(0);repeat(50)tick;
  if(loads!=0)$fatal(1,"empty catalog navigation underflow");
  $display("PASS: tb_training_pages");$finish;
 end
 initial begin #2000000;$fatal(1,"TIMEOUT training pages");end
endmodule
