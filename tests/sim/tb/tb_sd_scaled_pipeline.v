`timescale 1ns/1ps
// Actual scheduler + actual sector decoder/scaler + actual SDRAM write FSM.
// Only the card transport, dual-clock RAM FIFOs and SDRAM chip are models.
module tb_sd_scaled_pipeline #(parameter integer USE_BLUR=0,
                               parameter integer DW=64,
                               parameter integer DH=32,
                               parameter integer BURST=256);
 localparam [20:0] SLOT_WORDS=DW*DH;
 localparam [20:0] SLOT2_WORDS=2*DW*DH;
 localparam [20:0] SLOT3_WORDS=3*DW*DH;
 reg clk=0,mem_clk=0,rst=1,write_toggle=0,frame_start=0,key_next=1;
 always #5 clk=~clk;
 always #200 mem_clk=~mem_clk; // deliberately slow memory forces FIFO backpressure
 wire req,ack,en,space,finished,app_en,publish,done,valid;
 wire rd_request,rd_ack;
 wire [20:0] rd_addr;
 wire actual_frame_start;
 reg read_req=0;reg [2:0]read_return=0;
 integer video_cycle=0,read_commands=0,reads_during_load=0,reads_during_write=0,empty_wait=0;
wire read_enable=(video_cycle%20==0) && !memory_writer.read_buf.model.empty_flag;
 always @(posedge clk)video_cycle=video_cycle+1;
 always @(posedge mem_clk)begin
  read_return<={read_return[1:0],rd_request};
  if(!rst)begin
   if(rd_request)begin
    read_commands=read_commands+1;
    if(scheduler.load_busy)reads_during_load=reads_during_load+1;
    if(scheduler.writer_started && scheduler.load_busy)
     reads_during_write=reads_during_write+1;
   end
   if(memory_writer.wrusedw<64 && !rd_request)empty_wait=empty_wait+1;
   else empty_wait=0;
   if(empty_wait>600)$fatal(1,"background writes starved the video reader");
  end
 end
 initial begin
  wait(!rst);repeat(10)@(negedge clk);
  forever begin
   read_req=1;wait(rd_ack);@(negedge clk);read_req=0;
   wait(!rd_ack);repeat(2)@(negedge clk);
  end
 end
 wire [31:0]data,app_data;
 wire [20:0]addr;
 wire [1:0]write_index,publish_index,active;
 integer writes=0,loads=0,stalls=0,b,i,x,y,sx,sy,fw,fh,ox,top,bottom,w,h,pos;
 integer publish_count=0,slot_writes[0:3],reads_snapshot=0;
 integer frame_writes[0:3],write_requests[0:3],display_prefetch_loads=0;
 reg previous_req=0,display_before_all=0;
 reg [3:0] finished_slots=0;
 integer seen[0:4*DW*DH-1];
 reg [23:0] expected_pixels[0:4*DW*DH-1];
 reg [23:0]expected;
sd_card_bmp #(.CLK_FREQ_HZ(1000),.SCALE_ENABLE(1),.BLUR_BACKGROUND(USE_BLUR),
              .LOAD_TIMEOUT_CYCLES(200000),.READER_TIMEOUT_CYCLES(200000),
              .DST_WIDTH(DW),.DST_HEIGHT(DH),
              .SCAN_START_SECTOR(0),.SCAN_MAX_SECTOR(3)) scheduler(
  .clk(clk),.rst(rst),.key_next(key_next),.key_prev(1'b1),.key_auto(1'b1),.external_auto(1'b0),
  .training_active(1'b0),.training_next(1'b0),.training_prev(1'b0),.page_status(),.state_code(),.bmp_width(16'd640),.bmp_height(16'd480),.display_valid(valid),
  .write_finish_toggle(write_toggle),.write_buf_idx(write_index),.disp_buf_idx(publish_index),
  .publish_req(publish),.publish_done(done),.write_req(req),.write_req_ack(ack),
  .pixel_ready(space),.write_en(en),.write_data(data),
  .SD_nCS(),.SD_DCLK(),.SD_MOSI(),.SD_MISO(1'b1));
 frame_read_write #(.BURST_SIZE(BURST),.FRAME_WIDTH(DW),.FRAME_HEIGHT(DH)) memory_writer(
  .rst(rst),.mem_clk(mem_clk),.Sdr_init_done(!rst),.Sdr_init_ref_vld(1'b0),.Sdr_busy(1'b0),
  .App_rd_en(rd_request),.App_rd_addr(rd_addr),.Sdr_rd_en(read_return[2]),.Sdr_rd_dout(32'd0),
  .read_clk(clk),.read_req(read_req),.read_req_ack(rd_ack),.read_finish(),
  .read_addr_0(21'd0),.read_addr_1(SLOT_WORDS),.read_addr_2(SLOT2_WORDS),.read_addr_3(SLOT3_WORDS),
  .read_addr_index(active),.read_len(SLOT_WORDS),.read_en(read_enable),.read_data(),
  .App_wr_en(app_en),.App_wr_addr(addr),.App_wr_din(app_data),.App_wr_dm(),
  .write_clk(clk),.write_req(req),.write_req_ack(ack),.write_finish(finished),
  .write_addr_0(21'd0),.write_addr_1(SLOT_WORDS),.write_addr_2(SLOT2_WORDS),.write_addr_3(SLOT3_WORDS),
  .write_addr_index(write_index),.write_len(SLOT_WORDS),.write_en(en),.write_data(data),
  .frame_start(actual_frame_start),.write_ready(space));
 frame_buffer_publish publisher(clk,!rst,publish,publish_index,,done,mem_clk,!rst,
                                USE_BLUR?actual_frame_start:frame_start,active);
 always @(posedge mem_clk)begin
  if(rst)write_toggle<=0;
  else if(finished)begin
   write_toggle<=!write_toggle;
   frame_writes[write_index]=frame_writes[write_index]+1;
   if(frame_writes[write_index]!=1)$fatal(1,"multiple frame writes into one cache slot");
   finished_slots[write_index]=1'b1;
  end
  if(!rst && app_en)begin

   if(addr>=4*DW*DH)$fatal(1,"write outside four cache slots");
   b=addr/(DW*DH);pos=addr%(DW*DH);x=pos%DW;y=pos/DW;
   expected=expected_pixels[addr];
   if(app_data!=={expected,8'b0})$fatal(1,"SDRAM slot=%d x=%d y=%d data=%h expected=%h",b,x,y,app_data,{expected,8'b0});
   if(seen[addr])$fatal(1,"cached pixel overwritten");
   seen[addr]=1;writes=writes+1;slot_writes[b]=slot_writes[b]+1;
  end
  if(!rst && USE_BLUR && valid && rd_request)begin
   if(rd_addr>=4*DW*DH || !seen[rd_addr])
    $fatal(1,"display reader addressed an unfinished pixel %0d",rd_addr);
  end
 end
 function [23:0]source_pixel;
  input integer image,x,y;
  reg [7:0]r,g,b;
  begin r=image*50+x*7;g=y*29+x;b=image*11+y*3;source_pixel={r,g,b};end
 endfunction
function [23:0] model_pixel;
 input integer image,x,y;
 reg [7:0]r,g,b;
 begin r=image*50+x*7;g=y*29+x;b=image*11+y*3;model_pixel={r,g,b};end
endfunction

task build_reference;
 input integer image;
 integer iw,ih,fitw,fith,left,bot,cw,ch,cx,cy,bw,bh;
 integer ar[0:767],ag[0:767],ab[0:767],cnt[0:767];
 integer tr[0:767],tg[0:767],tb[0:767];
 integer x0,y0,x1,y1,xx,yy,idx,k,pass,dx,dy,sr,sg,sb;
 integer qx,qy,fx,fy,a,b,c,d,r,g,bl;
 reg [23:0]p;
 begin
  iw=image+3;ih=image+2;
  if(iw*DH>=ih*DW)begin fitw=DW;fith=(ih*DW+iw/2)/iw;if(fith<1)fith=1;
   cw=ih*DW/DH;if(cw<1)cw=1;ch=ih;cx=(iw-cw)/2;cy=0;end
  else begin fith=DH;fitw=(iw*DH+ih/2)/ih;if(fitw<1)fitw=1;
   cw=iw;ch=iw*DH/DW;if(ch<1)ch=1;cx=0;cy=(ih-ch+1)/2;end
  left=(DW-fitw)/2;bot=(DH-fith+1)/2;bw=(cw<32)?cw:32;bh=(ch<24)?ch:24;
  for(k=0;k<768;k=k+1)begin ar[k]=0;ag[k]=0;ab[k]=0;cnt[k]=0;end
  for(yy=cy;yy<cy+ch;yy=yy+1)for(xx=cx;xx<cx+cw;xx=xx+1)begin
   x1=(xx-cx)*bw/cw;y1=(yy-cy)*bh/ch;idx=y1*bw+x1;p=model_pixel(image,xx,yy);
   ar[idx]=ar[idx]+p[23:16];ag[idx]=ag[idx]+p[15:8];ab[idx]=ab[idx]+p[7:0];cnt[idx]=cnt[idx]+1;
  end
  for(k=0;k<bw*bh;k=k+1)begin ar[k]=ar[k]/cnt[k];ag[k]=ag[k]/cnt[k];ab[k]=ab[k]/cnt[k];end
  for(pass=0;pass<3;pass=pass+1)begin
   for(yy=0;yy<bh;yy=yy+1)for(xx=0;xx<bw;xx=xx+1)begin
    sr=0;sg=0;sb=0;
    for(dy=-1;dy<=1;dy=dy+1)for(dx=-1;dx<=1;dx=dx+1)begin
     x0=xx+dx;y0=yy+dy;if(x0<0)x0=0;if(x0>=bw)x0=bw-1;if(y0<0)y0=0;if(y0>=bh)y0=bh-1;idx=y0*bw+x0;
     sr=sr+ar[idx];sg=sg+ag[idx];sb=sb+ab[idx];
    end
    idx=yy*bw+xx;tr[idx]=sr/9;tg[idx]=sg/9;tb[idx]=sb/9;
   end
   for(k=0;k<bw*bh;k=k+1)begin ar[k]=tr[k];ag[k]=tg[k];ab[k]=tb[k];end
  end
  for(y0=0;y0<DH;y0=y0+1)for(x0=0;x0<DW;x0=x0+1)begin
   if(x0>=left&&x0<left+fitw&&y0>=bot&&y0<bot+fith)
    p=model_pixel(image,(x0-left)*iw/fitw,(y0-bot)*ih/fith);
   else if(!USE_BLUR)p=24'h102030;
   else begin
    qx=((2*x0+1)*bw*256)/(2*DW)-128;qy=((2*y0+1)*bh*256)/(2*DH)-128;
    if(qx<0)qx=0;if(qx>(bw-1)*256)qx=(bw-1)*256;if(qy<0)qy=0;if(qy>(bh-1)*256)qy=(bh-1)*256;
    fx=qx%256;fy=qy%256;x1=(qx/256<bw-1)?qx/256+1:qx/256;y1=(qy/256<bh-1)?qy/256+1:qy/256;
    a=(qy/256)*bw+qx/256;b=(qy/256)*bw+x1;c=y1*bw+qx/256;d=y1*bw+x1;
    r=(ar[a]*(256-fx)*(256-fy)+ar[b]*fx*(256-fy)+ar[c]*(256-fx)*fy+ar[d]*fx*fy+32768)/65536;
    g=(ag[a]*(256-fx)*(256-fy)+ag[b]*fx*(256-fy)+ag[c]*(256-fx)*fy+ag[d]*fx*fy+32768)/65536;
    bl=(ab[a]*(256-fx)*(256-fy)+ab[b]*fx*(256-fy)+ab[c]*(256-fx)*fy+ab[d]*fx*fy+32768)/65536;
    r=r*3/4;g=g*3/4;bl=bl*3/4;p={r[7:0],g[7:0],bl[7:0]};
   end
   // Writer flips input rows, so reference is indexed in SDRAM top-down order.
   expected_pixels[image*DW*DH+(DH-1-y0)*DW+x0]=p;
  end
 end
endtask
 always @(posedge clk)if(!rst)begin
  if(!space)stalls=stalls+1;
  if(scheduler.load_start_pulse)begin
   loads=loads+1;if(valid)display_prefetch_loads=display_prefetch_loads+1;
  end
  if(req && !previous_req)begin
   write_requests[write_index]=write_requests[write_index]+1;
   if(write_requests[write_index]!=1)$fatal(1,"cache slot opened for writing twice");
  end
  previous_req=req;
  if(valid && scheduler.cache_valid!=15)display_before_all=1;
  if((scheduler.cache_valid & ~finished_slots)!=0)
   $fatal(1,"cache marked valid before memory-domain write_finish");
  if(publish)begin
   publish_count=publish_count+1;
   if(!scheduler.cache_valid[publish_index] || !finished_slots[publish_index])
    $fatal(1,"published frame before its SDRAM write completed");
   if(slot_writes[publish_index] != DW*DH)
    $fatal(1,"published slot %0d before all pixels reached SDRAM",publish_index);
  end
 end
 integer boundary_count=0;
 always @(negedge mem_clk)begin
  boundary_count=boundary_count+1;frame_start=boundary_count%40==0;
 end
 initial begin
  for(i=0;i<4*DW*DH;i=i+1)seen[i]=0;
  for(i=0;i<4;i=i+1)begin
   slot_writes[i]=0;frame_writes[i]=0;write_requests[i]=0;build_reference(i);
  end
  repeat(5)@(negedge mem_clk);rst=0;
  wait(scheduler.cache_valid==15);
  repeat(100)@(negedge mem_clk);
  if(writes!=4*DW*DH || loads!=4 || !valid || (!USE_BLUR && stalls==0) ||
     read_commands==0 || reads_during_load==0 || reads_during_write==0)
   $fatal(1,"pipeline incomplete writes=%0d loads=%0d valid=%b stalls=%0d reads=%0d load_reads=%0d write_reads=%0d",
          writes,loads,valid,stalls,read_commands,reads_during_load,reads_during_write);
  if(!display_before_all || display_prefetch_loads==0 || publish_count==0)
   $fatal(1,"first display did not run concurrently with background prefetch");
  for(i=0;i<4;i=i+1)if(slot_writes[i]!=DW*DH || frame_writes[i]!=1 || write_requests[i]!=1)
   $fatal(1,"slot %0d not written exactly once",i);
  if(USE_BLUR && scheduler.sd_card_top_m0.model_read_count!=16)
   $fatal(1,"expected 4 scans + 4 headers + 8 source passes, got %0d",scheduler.sd_card_top_m0.model_read_count);
  @(negedge clk);key_next=0;repeat(30)@(negedge clk);key_next=1;
  wait(active==1);repeat(10)@(negedge mem_clk);
  if(writes!=4*DW*DH || loads!=4)$fatal(1,"cached switch loaded pixels again");
  reads_snapshot=scheduler.sd_card_top_m0.model_read_count;
  repeat(1000)@(negedge clk);
  if(scheduler.sd_card_top_m0.model_read_count!=reads_snapshot)
   $fatal(1,"SD read after cache completion");
  if(USE_BLUR)$display("PASS tb_sd_blur_pipeline: blur composite in all four SDRAM slots, concurrent display reads, publish after write finish, cached switch");
  else $display("PASS tb_sd_scaled_pipeline: complete four-slot SDRAM writes, V flip, FIFO backpressure, cached switch");
  $finish;
 end
 initial begin #20000000;
  $fatal(1,"TIMEOUT writes=%0d loads=%0d valid=%b cache=%b",writes,loads,valid,scheduler.cache_valid);
 end
endmodule

module tb_sd_blur_pipeline;
 tb_sd_scaled_pipeline #(.USE_BLUR(1),.DW(8),.DH(4),.BURST(4)) test();
endmodule

module sd_card_top #(parameter TOKEN_TIMEOUT_CYCLES=10000000,
 parameter SPI_TIMEOUT_CYCLES=1000000)(
 input read_cancel,output sd_sec_ready,sd_sec_read_error,
 input clk,rst,output SD_nCS,SD_DCLK,SD_MOSI,input SD_MISO,
 output sd_init_done,input sd_sec_read,input[31:0]sd_sec_read_addr,
 output reg[7:0]sd_sec_read_data=0,output reg sd_sec_read_data_valid=0,sd_sec_read_end=0,
 input sd_sec_write,input[31:0]sd_sec_write_addr,input[7:0]sd_sec_write_data,
 output sd_sec_write_data_req,sd_sec_write_end);
 reg [31:0] model_read_count=0;
 assign sd_sec_ready=!rst;assign sd_sec_read_error=0;
 assign sd_init_done=!rst;assign SD_nCS=1;assign SD_DCLK=0;assign SD_MOSI=1;
 assign sd_sec_write_data_req=0;assign sd_sec_write_end=0;
 integer image,w,h,stride,length,i,n,x,y,c;
 reg[23:0]p;
 initial forever begin
  wait(!rst && sd_sec_read);
  model_read_count=model_read_count+1;
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
     c=(n%stride)%3;p=model_pixel(image,x,y);
     sd_sec_read_data=(n%stride<w*3)?(p>>(8*c)):8'hee;
    end
   endcase
  end
  @(negedge clk);sd_sec_read_data_valid=0;
  repeat(3)@(negedge clk);sd_sec_read_end=1;
  @(negedge clk);sd_sec_read_end=0;wait(!sd_sec_read);
 end
 function [23:0]model_pixel;
  input integer image,x,y;
  reg [7:0]r,g,b;
  begin r=image*50+x*7;g=y*29+x;b=image*11+y*3;model_pixel={r,g,b};end
 endfunction
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
