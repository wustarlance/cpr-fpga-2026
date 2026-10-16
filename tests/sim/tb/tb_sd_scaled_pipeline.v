`timescale 1ns/1ps
// Actual scheduler + actual sector decoder/scaler + actual SDRAM write FSM.
// Only the card transport, dual-clock RAM FIFOs and SDRAM chip are models.
module tb_sd_scaled_pipeline;
 reg clk=0,mem_clk=0,rst=1,write_toggle=0,frame_start=0,key_next=1;
 always #5 clk=~clk;
 always #200 mem_clk=~mem_clk; // deliberately slow memory forces FIFO backpressure
 wire req,ack,en,space,finished,app_en,publish,done,valid;
 wire rd_request,rd_ack;
 reg read_req=0;reg [2:0]read_return=0;
 integer video_cycle=0,read_commands=0,empty_wait=0;
 wire read_enable=(video_cycle%200==0) && !memory_writer.read_buf.model.empty_flag;
 always @(posedge clk)video_cycle=video_cycle+1;
 always @(posedge mem_clk)begin
  read_return<={read_return[1:0],rd_request};
  if(!rst)begin
   if(rd_request)read_commands=read_commands+1;
   if(memory_writer.wrusedw<64 && !rd_request)empty_wait=empty_wait+1;
   else empty_wait=0;
   if(empty_wait>600)$fatal(1,"background writes starved the video reader");
  end
 end
 initial begin
  wait(!rst);@(negedge clk);read_req=1;wait(rd_ack);
  @(negedge clk);read_req=0;
 end
 wire [31:0]data,app_data;
 wire [20:0]addr;
 wire [1:0]write_index,publish_index,active;
 integer writes=0,loads=0,stalls=0,b,i,x,y,sx,sy,fw,fh,ox,top,bottom,w,h,pos;
 integer seen[0:8191];
 reg [23:0]expected;
 sd_card_bmp #(.CLK_FREQ_HZ(1000),.SCALE_ENABLE(1),.LOAD_TIMEOUT_CYCLES(2000000),.READER_TIMEOUT_CYCLES(200000),.DST_WIDTH(64),.DST_HEIGHT(32),
              .SCAN_START_SECTOR(0),.SCAN_MAX_SECTOR(3)) scheduler(
  .clk(clk),.rst(rst),.key_next(key_next),.key_prev(1'b1),.key_auto(1'b1),.external_auto(1'b0),
  .training_active(1'b0),.training_next(1'b0),.training_prev(1'b0),.page_status(),.state_code(),.bmp_width(16'd640),.bmp_height(16'd480),.display_valid(valid),
  .write_finish_toggle(write_toggle),.write_buf_idx(write_index),.disp_buf_idx(publish_index),
  .publish_req(publish),.publish_done(done),.write_req(req),.write_req_ack(ack),
  .pixel_ready(space),.write_en(en),.write_data(data),
  .SD_nCS(),.SD_DCLK(),.SD_MOSI(),.SD_MISO(1'b1));
 frame_read_write #(.FRAME_WIDTH(64),.FRAME_HEIGHT(32)) memory_writer(
  .rst(rst),.mem_clk(mem_clk),.Sdr_init_done(!rst),.Sdr_init_ref_vld(1'b0),.Sdr_busy(1'b0),
  .App_rd_en(rd_request),.App_rd_addr(),.Sdr_rd_en(read_return[2]),.Sdr_rd_dout(32'd0),
  .read_clk(clk),.read_req(read_req),.read_req_ack(rd_ack),.read_finish(),
  .read_addr_0(21'd0),.read_addr_1(21'd2048),.read_addr_2(21'd4096),.read_addr_3(21'd6144),
  .read_addr_index(active),.read_len(21'd32768),.read_en(read_enable),.read_data(),
  .App_wr_en(app_en),.App_wr_addr(addr),.App_wr_din(app_data),.App_wr_dm(),
  .write_clk(clk),.write_req(req),.write_req_ack(ack),.write_finish(finished),
  .write_addr_0(21'd0),.write_addr_1(21'd2048),.write_addr_2(21'd4096),.write_addr_3(21'd6144),
  .write_addr_index(write_index),.write_len(21'd2048),.write_en(en),.write_data(data),
  .frame_start(),.write_ready(space));
 frame_buffer_publish publisher(clk,!rst,publish,publish_index,,done,mem_clk,!rst,frame_start,active);
 always @(posedge mem_clk)begin
  if(rst)write_toggle<=0;
  else if(finished)write_toggle<=!write_toggle;
  if(!rst && app_en)begin

   if(addr>=8192)$fatal(1,"write outside four cache slots");
   b=addr/2048;pos=addr%2048;x=pos%64;y=pos/64;w=b+3;h=b+2;
   if(w*32>=h*64)begin fw=64;fh=(h*64+w/2)/w;end
   else begin fh=32;fw=(w*32+h/2)/h;end
   ox=(64-fw)/2;top=(32-fh)/2;bottom=32-fh-top;
   expected=24'h102030;
   if(x>=ox && x<ox+fw && y>=top && y<top+fh)begin
    sx=(x-ox)*w/fw;sy=(31-y-bottom)*h/fh;
    expected=source_pixel(b,sx,sy);
   end
   if(app_data!=={expected,8'b0})$fatal(1,"SDRAM slot=%d x=%d y=%d data=%h expected=%h",b,x,y,app_data,{expected,8'b0});
   if(seen[addr])$fatal(1,"cached pixel overwritten");
   seen[addr]=1;writes=writes+1;
  end
 end
 function [23:0]source_pixel;
  input integer image,x,y;
  reg [7:0]r,g,b;
  begin r=image*50+x*7;g=y*29+x;b=image*11+y*3;source_pixel={r,g,b};end
 endfunction
 always @(posedge clk)if(!rst)begin
  if(!space)stalls=stalls+1;
  if(scheduler.load_start_pulse)loads=loads+1;
 end
 integer boundary_count=0;
 always @(negedge mem_clk)begin
  boundary_count=boundary_count+1;frame_start=boundary_count%40==0;
 end
 initial begin
  for(i=0;i<8192;i=i+1)seen[i]=0;
  repeat(5)@(negedge mem_clk);rst=0;
  wait(scheduler.cache_valid==15);
  repeat(100)@(negedge mem_clk);
  if(writes!=8192 || loads!=4 || !valid || stalls==0 || read_commands<1024)
   $fatal(1,"pipeline incomplete writes=%0d loads=%0d valid=%b stalls=%0d",writes,loads,valid,stalls);
  @(negedge clk);key_next=0;repeat(30)@(negedge clk);key_next=1;
  wait(active==1);repeat(10)@(negedge mem_clk);
  if(writes!=8192 || loads!=4)$fatal(1,"cached switch loaded pixels again");
  $display("PASS tb_sd_scaled_pipeline: complete four-slot SDRAM writes, V flip, FIFO backpressure, cached switch");$finish;
 end
 initial begin #20000000;
  $fatal(1,"TIMEOUT writes=%0d loads=%0d valid=%b cache=%b",writes,loads,valid,scheduler.cache_valid);
 end
endmodule

module sd_card_top #(parameter TOKEN_TIMEOUT_CYCLES=10000000,
 parameter SPI_TIMEOUT_CYCLES=1000000)(
 input read_cancel,output sd_sec_ready,sd_sec_read_error,
 input clk,rst,output SD_nCS,SD_DCLK,SD_MOSI,input SD_MISO,
 output sd_init_done,input sd_sec_read,input[31:0]sd_sec_read_addr,
 output reg[7:0]sd_sec_read_data=0,output reg sd_sec_read_data_valid=0,sd_sec_read_end=0,
 input sd_sec_write,input[31:0]sd_sec_write_addr,input[7:0]sd_sec_write_data,
 output sd_sec_write_data_req,sd_sec_write_end);
 assign sd_sec_ready=!rst;assign sd_sec_read_error=0;
 assign sd_init_done=!rst;assign SD_nCS=1;assign SD_DCLK=0;assign SD_MOSI=1;
 assign sd_sec_write_data_req=0;assign sd_sec_write_end=0;
 integer image,w,h,stride,length,i,n,x,y,c;
 reg[23:0]p;
 initial forever begin
  wait(!rst && sd_sec_read);
  image=sd_sec_read_addr;w=image+3;h=image+2;stride=(w*3+3)&~3;length=80+stride*h;
  for(i=0;i<512;i=i+1)begin
   @(negedge clk);sd_sec_read_data_valid=1;sd_sec_read_data=0;
   case(i)
    0:sd_sec_read_data="B";1:sd_sec_read_data="M";
    2:sd_sec_read_data=length;3:sd_sec_read_data=length>>8;
    10:sd_sec_read_data=80;14:sd_sec_read_data=40;
    18:sd_sec_read_data=w;22:sd_sec_read_data=h;26:sd_sec_read_data=1;28:sd_sec_read_data=24;
    default:if(i>=80)begin
     n=i-80;x=(n%stride)/3;y=n/stride;c=n%3;
     // RGB assembly uses row-relative channel, including BMP padding.
     c=(n%stride)%3;p=tb_sd_scaled_pipeline.source_pixel(image,x,y);
     sd_sec_read_data=(n%stride<w*3)?(p>>(8*c)):8'hee;
    end
   endcase
  end
  @(negedge clk);sd_sec_read_data_valid=0;
  repeat(3)@(negedge clk);sd_sec_read_end=1;
  @(negedge clk);sd_sec_read_end=0;wait(!sd_sec_read);
 end
endmodule

// Show-ahead asynchronous FIFO model with synchronized pointers, matching the
// public generated FIFO interface and its 511-word effective capacity.
module wfifo_32_32_512(
 input rst,clkw,clkr,we,re,input[31:0]di,output[31:0]dout,
 output empty_flag,full_flag,output[8:0]wrusedw,rdusedw);
 reg[31:0]ram[0:511];reg[9:0]wp=0,rp=0,wm=0,ws=0,rm=0,rs=0;
 assign wrusedw=wp-rs;assign rdusedw=ws-rp;
 wire [9:0] occupancy=wp-rs;
 assign empty_flag=ws==rp;assign full_flag=occupancy>=10'd511;
 assign dout=ram[rp[8:0]];
 always @(posedge clkw or posedge rst)begin
  if(rst)begin wp<=0;rm<=0;rs<=0;end
  else begin rm<=rp;rs<=rm;if(we)begin
   if(full_flag)$fatal(1,"producer overflowed write FIFO");
   ram[wp[8:0]]<=di;wp<=wp+1'b1;
  end end
 end
 always @(posedge clkr or posedge rst)begin
  if(rst)begin rp<=0;wm<=0;ws<=0;end
  else begin wm<=wp;ws<=wm;if(re)begin
   if(empty_flag)$fatal(1,"memory writer underflowed FIFO");rp<=rp+1'b1;
  end end
 end
endmodule
module rfifo_32_32_512(
 input rst,clkw,clkr,we,re,input[31:0]di,output[31:0]dout,
 output empty_flag,full_flag,output[8:0]wrusedw,rdusedw);
 wfifo_32_32_512 model(rst,clkw,clkr,we,re,di,dout,empty_flag,full_flag,wrusedw,rdusedw);

endmodule
