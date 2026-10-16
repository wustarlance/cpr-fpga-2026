`timescale 1ns/1ps
module tb_sd_image_recovery;
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
 sd_card_bmp #(.CLK_FREQ_HZ(1000),.SCALE_ENABLE(0),.READER_TIMEOUT_CYCLES(80),
  .LOAD_TIMEOUT_CYCLES(2500),.SCAN_MAX_SECTOR(1),.SCAN_TARGET_COUNT(2)) dut(
  .clk(clk),.rst(!rst_n),.key_next(key_next),.key_prev(1'b1),
  .key_auto(1'b1),.external_auto(1'b0),
  .training_active(1'b0),.training_next(1'b0),.training_prev(1'b0),.page_status(),.state_code(state_code),.media_error(media_error),
  .bmp_width(16'd4),.bmp_height(16'd2),.display_valid(display_valid),
  .write_finish_toggle(hold_finish?frozen_toggle:write_toggle),
  .write_buf_idx(write_index),.disp_buf_idx(pending_index),
  .publish_req(publish),.publish_done(done),.write_req(write_req),
  .write_req_ack(writer_ack&&!hold_ack),.pixel_ready(1'b1),.write_en(write_en),.write_data(write_data),
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
   frame_counter<=frame_counter+1;frame_start<=(frame_counter%30)==0;
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
   w=0;while(!display_valid||dut.img_idx!=index||dut.load_busy)begin
    tick;w=w+1;if(w>15000)$fatal(1,"image never adopted case=%0d error=%0d loads=%0d state=%h",test_case,media_error,loads,state_code);
   end
   // Check all real writer addresses and all eight RGB values after adoption.
   offset=active_index*64;
   for(p=0;p<8;p=p+1)begin
    b=(index==0?32:128)+p*3;c=b+1;j=b+2;
    if(memory[offset+(1-p/4)*4+p%4]!=={j[7:0],c[7:0],b[7:0],8'd0})
     $fatal(1,"recovered image contains stale/missing pixel %0d",p);
   end
  end
 endtask
 task setup;
  begin
   rst_n=0;key_next=1;hold_ack=0;hold_finish=0;
   dut.sd_card_top_m0.fault_kind=0;dut.sd_card_top_m0.fail_budget=0;
   dut.sd_card_top_m0.fail_sector=1;dut.sd_card_top_m0.only_transaction=0;
   repeat(5)tick;rst_n=1;wait_image(0);
   if(loads!=1||publications!=1)$fatal(1,"initial publication failed");
  end
 endtask
 initial begin
  for(test_case=1;test_case<=7;test_case=test_case+1)begin
   setup;frozen_toggle=write_toggle;
   case(test_case)
    1:begin dut.sd_card_top_m0.fault_kind=1;dut.sd_card_top_m0.fail_budget=1;end
    2:begin dut.sd_card_top_m0.fault_kind=1;dut.sd_card_top_m0.fail_budget=-1;end
    3:begin dut.sd_card_top_m0.fault_kind=2;dut.sd_card_top_m0.fail_budget=-1;end
    4:begin dut.sd_card_top_m0.fault_kind=3;dut.sd_card_top_m0.fail_budget=1;
       dut.sd_card_top_m0.only_transaction=dut.sd_card_top_m0.transactions+2;end
    5:begin dut.sd_card_top_m0.fault_kind=4;dut.sd_card_top_m0.fail_budget=-1;end
    6:hold_ack=1;
    7:hold_finish=1;
   endcase
   press;
   if(test_case==1||test_case==4)begin
    wait_image(1);
    if(loads!=3||publications!=2)$fatal(1,"retry did not use exactly one extra attempt");
   end else begin
    w=0;while(!dut.media_fault)begin tick;w=w+1;if(w>15000)$fatal(1,"retry limit never reached");end
    if(loads!=3||publications!=1||!display_valid||active_index!=0||dut.img_idx!=0||dut.load_busy)
     $fatal(1,"failed attempts changed display or retry bound");
    if(media_error!=(test_case==3?4:test_case==5?2:test_case>=6?3:1))
     $fatal(1,"wrong error reason case=%0d code=%0d",test_case,media_error);
    wait_image(0);
    repeat(200)tick;
    if(loads!=3||publications!=1)$fatal(1,"automatic retry continued after bound");
    dut.sd_card_top_m0.fail_budget=0;hold_ack=0;hold_finish=0;
    press;wait_image(1);
    if(loads!=4||media_error!=0)$fatal(1,"manual recovery did not clear error");
   end
   $display("CHECK image recovery scenario %0d passed",test_case);
  end
  // Scan failures must also stop after a bounded retry; a manual retry rescans.
  test_case=8;rst_n=0;repeat(5)tick;
  dut.sd_card_top_m0.fault_kind=1;dut.sd_card_top_m0.fail_budget=-1;
  dut.sd_card_top_m0.fail_sector=0;dut.sd_card_top_m0.only_transaction=0;
  rst_n=1;w=0;
  while(!dut.media_fault)begin tick;w=w+1;if(w>1000)$fatal(1,"scan did not terminate on failure");end
  if(display_valid||publications!=0||dut.sd_card_top_m0.transactions!=2)
   $fatal(1,"scan error published a frame or retried indefinitely");
  dut.sd_card_top_m0.fail_budget=0;press;wait_image(0);
  $display("CHECK failed scan, manual rescan and first image recovered");
  $display("PASS: tb_sd_image_recovery");$finish;
 end
 initial begin #2000000;$fatal(1,"TIMEOUT image recovery");end
endmodule
