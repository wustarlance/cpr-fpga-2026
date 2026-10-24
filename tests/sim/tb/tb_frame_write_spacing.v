`timescale 1ns/1ps
module tb_frame_write_spacing #(parameter GAP=64,H=2);
 localparam N=640*H;
 reg mem_clk=0,write_clk=0,rst=1,write_req=0,write_en=0;
 always #12.5 mem_clk=~mem_clk;
 always #5 write_clk=~write_clk;
 reg [1:0] slot_index=0;
 reg [31:0] data=0;
 wire ack,finish,ready,wr,rd;wire [20:0] addr,rdaddr;wire [31:0] dout,rdata;wire [3:0] dm;
 integer cycle=0;reg forced_refresh=0;integer force_left=0;integer run=0;
 always @(negedge mem_clk)begin
  if(rst)begin force_left=0;forced_refresh=0;end
  else begin
   if(force_left==0 && run==17)force_left=7;
   forced_refresh=force_left!=0;
   if(force_left!=0)force_left=force_left-1;
  end
 end
 wire refresh=forced_refresh || ((cycle%1169)>=400 && (cycle%1169)<407);
 frame_read_write #(.WRITE_BURST_SIZE(128),.WRITE_TO_READ_GAP(16),.WRITE_RESTART_GAP(GAP),.FRAME_WIDTH(640),.FRAME_HEIGHT(H)) dut(
 .rst(rst),.mem_clk(mem_clk),.Sdr_init_done(!rst),.Sdr_init_ref_vld(refresh),.Sdr_busy(1'b0),
 .App_wr_en(wr),.App_wr_addr(addr),.App_wr_din(dout),.App_wr_dm(dm),.App_rd_en(rd),.App_rd_addr(rdaddr),.Sdr_rd_en(1'b0),.Sdr_rd_dout(32'd0),
 .write_clk(write_clk),.write_req(write_req),.write_req_ack(ack),.write_finish(finish),.write_ready(ready),.write_en(write_en),.write_data(data),
 .write_addr_0(21'd0),.write_addr_1(21'(N)),.write_addr_2(21'(2*N)),.write_addr_3(21'(3*N)),.write_addr_index(slot_index),.write_len(21'(N)),
 .read_clk(write_clk),.read_req(1'b0),.read_en(1'b0),.read_req_ack(),.read_finish(),.read_data(rdata),.frame_start(),
 .read_addr_0(21'd0),.read_addr_1(21'd307200),.read_addr_2(21'd614400),.read_addr_3(21'd921600),.read_addr_index(2'd0),.read_len(21'd307200),.diagnostic_pause(1'b0));

 function [31:0] oracle;input integer ordinal;begin oracle=32'h69b40000 ^ (ordinal*32'h01010301);end endfunction
 integer writes=0,bursts=0,last_cycle=-100000,min_gap=100000,refresh_inside=0;
 integer k,want_addr,expected_slot;
 always @(posedge mem_clk)if(!rst)begin
  cycle=cycle+1;
  if(rd)$fatal(1,"unexpected read");
  if(wr)begin
   if(writes>=4*N)$fatal(1,"extra write");
   expected_slot=writes/N;k=writes%N;
   want_addr=expected_slot*N+(H-1-k/640)*640+k%640;
   if(addr!==want_addr || dout!==oracle(writes) || dm!==0 || dut.probe_write_empty)
    $fatal(1,"whole-frame sequence %0d address=%0d expected=%0d data=%h expected=%h",writes,addr,want_addr,dout,oracle(writes));
   if(run==0)begin
    if(refresh || addr[1:0]!=0)$fatal(1,"bad burst start");
    if(writes!=0)begin
     if(cycle-last_cycle-1<min_gap)min_gap=cycle-last_cycle-1;
     if(cycle-last_cycle-1<GAP)$fatal(1,"gap too short %0d required%0d",cycle-last_cycle-1,GAP);
    end
   end else if(refresh)refresh_inside=refresh_inside+1;
   writes=writes+1;run=run+1;last_cycle=cycle;
  end else if(run!=0)begin
   if(run!=128)$fatal(1,"broken burst %0d",run);
   run=0;bursts=bursts+1;
  end
 end
 integer slot,p,producer_cycle=0,stalls=0;
 initial begin
  repeat(10)@(negedge write_clk);rst=0;
  for(slot=0;slot<4;slot=slot+1)begin
   @(negedge write_clk);slot_index=slot;write_req=1;
   wait(ack);@(negedge write_clk);write_req=0;
   wait(!ack);repeat(8)@(negedge write_clk);p=0;
   while(p<N)begin
    @(negedge write_clk);producer_cycle=producer_cycle+1;
    write_en=ready && producer_cycle%41>3;
    if(write_en)begin data=oracle(slot*N+p);p=p+1;end else stalls=stalls+1;
   end
   @(negedge write_clk);write_en=0;
   wait(finish);repeat(10)@(negedge write_clk);
   if(writes!=(slot+1)*N)$fatal(1,"early finish %0d",writes);
   $display("PROGRESS gap%0d H%0d frame%0d writes%0d bursts%0d run%0d stalls%0d refresh%0d time%0t",GAP,H,slot,writes,bursts,run,stalls,refresh_inside,$time);$fflush();
  end
  if(writes!=4*N || bursts!=4*N/128 || stalls==0 || refresh_inside==0)$fatal(1,"coverage missing writes=%0d bursts=%0d run=%0d stalls=%0d refresh=%0d min_gap=%0d",writes,bursts,run,stalls,refresh_inside,min_gap);
  $display("PASS: tb_frame_write_spacing writes=%0d bursts=%0d min_idle=%0d gap=%0d source_stalls=%0d ongoing_refresh_words=%0d",writes,bursts,min_gap,GAP,stalls,refresh_inside);$finish;
 end
 initial begin #200000000;$fatal(1,"timeout writes=%0d slot=%0d state=%0d",writes,slot,dut.frame_fifo_write_m0.state);end
endmodule
