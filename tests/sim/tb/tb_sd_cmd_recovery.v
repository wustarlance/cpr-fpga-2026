`timescale 1ns/1ps
// Byte-interface fault injection. SPI electrical timing is a separate concern.
module tb_sd_cmd_recovery;
 reg clk=0,rst=1,cancel=0,cmd_req=0,read_req=0,ack=0;
 reg[7:0] rx=8'hff;
 wire ready,done,error,valid,cs,request,abort_byte,cmd_ack,cmd_error;
 wire[7:0] data,tx;
 integer ends=0,errors=0,bytes=0,commands=0,watch,base_ends,base_errors,base_bytes,i;
 reg[7:0] payload[0:513];
 always #5 clk=~clk;
 always @(posedge clk) begin
  if(!rst && cmd_ack)cmd_req<=0;
  if(!rst && done)read_req<=0;
 end
 sd_card_cmd #(.TOKEN_TIMEOUT_CYCLES(80),.SPI_TIMEOUT_CYCLES(16)) dut(
  .sys_clk(clk),.rst(rst),.read_cancel(cancel),.ready(ready),
  .block_read_error(error),.spi_abort(abort_byte),.spi_clk_div(16'd0),
  .cmd_req(cmd_req),.cmd_req_ack(cmd_ack),.cmd_req_error(cmd_error),
  .cmd({8'd17,32'd9,8'hff}),.cmd_r1(8'h00),.cmd_data_len(16'd0),
  .block_read_req(read_req),.block_read_req_ack(done),
  .block_read_valid(valid),.block_read_data(data),
  .block_write_req(1'b0),.block_write_data(8'd0),.block_write_data_rd(),.block_write_req_ack(),
  .nCS_ctrl(cs),.clk_div(),.spi_wr_req(request),.spi_wr_ack(ack),
  .spi_data_in(tx),.spi_data_out(rx));
 always @(posedge clk) begin
  #1;
  if(!rst)begin
   if(done)begin ends=ends+1;if(error)errors=errors+1;end
   if(cmd_ack)commands=commands+1;
   if(valid)begin
    if(data!==payload[(bytes-base_bytes)%512])$fatal(1,"byte ordering/data mismatch");
    bytes=bytes+1;
   end
  end
 end
 task tick;begin @(negedge clk);end endtask
 task spi_byte;
  input[7:0] value;
  begin
   watch=0;while(!request)begin tick;watch=watch+1;if(watch>40)$fatal(1,"missing SPI request");end
   tick;rx=value;ack=1;tick;ack=0;repeat(2)tick;
  end
 endtask
 task idle;
  integer n;
  begin
   read_req=0;cmd_req=0;ack=0;
   n=0;while(!ready)begin
    if(request)spi_byte(8'hff);else tick;
    n=n+1;if(n>100)$fatal(1,"transport never recovered state=%0d req=%b command=%b read=%b count=%0d",dut.state,request,cmd_req,read_req,dut.byte_cnt);
   end
  end
 endtask
 task command17;
  integer n,old;
  begin
   idle;old=commands;tick;cmd_req=1;
   spi_byte(8'hff); // pre-command deselected dummy byte
   for(n=0;n<6;n=n+1)spi_byte(8'hff);
   spi_byte(8'h00);
   tick;cmd_req=0;
   if(commands!=old+1||cmd_error)$fatal(1,"CMD17 response failed");
   idle;
  end
 endtask
 task start_read;
  begin
   command17;
   base_ends=ends;base_errors=errors;base_bytes=bytes;
   tick;read_req=1;tick;
  end
 endtask
 task check_done;
  input integer expected_error,expected_bytes;
  integer n;
  begin
   n=0;while(ends==base_ends)begin tick;n=n+1;if(n>100)$fatal(1,"missing bounded completion");end
   if(ends!=base_ends+1||errors!=base_errors+expected_error||bytes!=base_bytes+expected_bytes)
    $fatal(1,"completion/error/byte count mismatch ends=%0d errors=%0d bytes=%0d",ends-base_ends,errors-base_errors,bytes-base_bytes);
   if(cs!==1'b1)$fatal(1,"card not deselected at completion");
   idle;
   if(ends!=base_ends+1)$fatal(1,"duplicate completion after recovery");
  end
 endtask
 initial begin
  $readmemh("fixtures/sd_crc_sector.mem",payload);
  repeat(4)tick;rst=0;
  // Initial dummy clocks; every byte must complete within the configured gap.
  for(i=0;i<11;i=i+1)spi_byte(8'hff);
  idle;

  start_read;
  while(ends==base_ends)begin
   if(request)spi_byte(8'hff);else tick;
  end
  check_done(1,0);
  $display("CHECK missing token -> bounded error, CS release and recovery");

  start_read;spi_byte(8'h0b);check_done(1,0);
  $display("CHECK data-error token rejected");

  start_read;spi_byte(8'hfe);
  for(i=0;i<514;i=i+1)spi_byte(payload[i]);
  check_done(0,512);
  $display("CHECK 512 known bytes plus independent CRC accepted after an error");

  start_read;spi_byte(8'hfe);
  for(i=0;i<513;i=i+1)spi_byte(payload[i]);
  spi_byte(payload[513]^8'h01);check_done(1,512);
  $display("CHECK bad CRC prevents successful sector completion");

  start_read;spi_byte(8'hfe);
  for(i=0;i<16;i=i+1)spi_byte(payload[i]);
  check_done(1,16);
  $display("CHECK stalled SPI mid-sector -> bounded failure");

  start_read;spi_byte(8'hfe);spi_byte(payload[0]);
  tick;cancel=1;tick;cancel=0;
  check_done(1,1);
  $display("CHECK explicit cancellation discards in-flight transaction");

  start_read;
  // Token on the final allowed clock wins over the token timeout.
  while(dut.token_wait<72)spi_byte(8'hff);
  while(dut.token_wait<79)tick;
  rx=8'hfe;ack=1;tick;ack=0;repeat(2)tick;
  for(i=0;i<514;i=i+1)spi_byte(payload[i]);
  check_done(0,512);
  $display("CHECK token accepted on exact deadline");
  $display("PASS: tb_sd_cmd_recovery");$finish;
 end
 initial begin #500000;$fatal(1,"TIMEOUT sd command recovery");end
endmodule
