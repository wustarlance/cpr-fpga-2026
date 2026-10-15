`timescale 1ns/1ps
module tb_sd_sector_recovery;
 reg clk=0,rst=1,cancel=0,cmd_ready=1,cmd_ack=0,cmd_error=0;
 reg read_req=0,block_ack=0,block_error=0;
 wire init_done,ready,ended,read_error,cmd_req,block_req;
 wire[47:0]cmd;
 integer n,ends=0,errors=0,old;
 always #5 clk=~clk;
 always @(posedge clk)if(!rst&&ended)read_req<=0;
 sd_card_sec_read_write dut(
  .clk(clk),.rst(rst),.read_cancel(cancel),.cmd_ready(cmd_ready),
  .block_read_error(block_error),.sd_sec_ready(ready),.sd_sec_read_error(read_error),
  .sd_init_done(init_done),.sd_sec_read(read_req),.sd_sec_read_addr(32'd123),
  .sd_sec_read_data(),.sd_sec_read_data_valid(),.sd_sec_read_end(ended),
  .sd_sec_write(1'b0),.sd_sec_write_addr(32'd0),.sd_sec_write_data(8'd0),
  .sd_sec_write_data_req(),.sd_sec_write_end(),.spi_clk_div(),
  .cmd_req(cmd_req),.cmd_req_ack(cmd_ack),.cmd_req_error(cmd_error),
  .cmd(cmd),.cmd_r1(),.cmd_data_len(),.block_read_req(block_req),
  .block_read_valid(1'b0),.block_read_data(8'd0),.block_read_req_ack(block_ack),
  .block_write_req(),.block_write_data(),.block_write_data_rd(1'b0),.block_write_req_ack(1'b0));
 always @(posedge clk)begin #1;if(!rst&&ended)begin ends=ends+1;if(read_error)errors=errors+1;end end
 task tick;begin @(negedge clk);end endtask
 task wait_command;
  input[7:0]code;
  integer w;
  begin w=0;while(!cmd_req)begin tick;w=w+1;if(w>30)$fatal(1,"no command");end
   if(cmd[47:40]!=code)$fatal(1,"unexpected command %0d wanted %0d",cmd[47:40],code);
  end
 endtask
 task respond;
  input fail;
  begin tick;cmd_error=fail;cmd_ack=1;tick;cmd_ack=0;cmd_error=0;repeat(2)tick;end
 endtask
 task start;
  begin while(!ready)tick;old=ends;tick;read_req=1;wait_command(17);
   if(cmd[39:8]!=123)$fatal(1,"sector address changed");end
 endtask
 task finish;
  input integer failures;
  begin tick;read_req=0;repeat(4)tick;
   if(ends!=old+1||errors!=failures||!ready||cmd_req||block_req||!init_done)
    $fatal(1,"completion invariant ends=%0d old=%0d errors=%0d expected=%0d ready=%b cmd=%b block=%b init=%b state=%0d",ends,old,errors,failures,ready,cmd_req,block_req,init_done,dut.state);end
 endtask
 initial begin
  repeat(3)tick;rst=0;
  wait_command(0);respond(0);wait_command(8);respond(0);
  wait_command(55);respond(0);wait_command(41);respond(0);
  wait_command(16);respond(0);
  start;respond(1);finish(1);
  $display("CHECK failed CMD17 terminates instead of unlimited command retry");
  start;respond(0);while(!block_req)tick;
  tick;block_error=1;block_ack=1;tick;block_ack=0;block_error=0;finish(2);
  $display("CHECK lower block failure reaches public sector error/end");
  start;respond(0);while(!block_req)tick;
  tick;block_ack=1;tick;block_ack=0;finish(2);
  $display("CHECK successful read after failures preserves initialization");
  start;tick;cancel=1;tick;cancel=0;finish(3);
  cmd_ready=0;tick;read_req=1;repeat(10)tick;
  if(cmd_req||block_req||ready)$fatal(1,"request accepted while command layer recovering");
  read_req=0;cmd_ready=1;
  $display("PASS: tb_sd_sector_recovery");$finish;
 end
 initial begin #30000;$fatal(1,"TIMEOUT sector layer");end
endmodule
