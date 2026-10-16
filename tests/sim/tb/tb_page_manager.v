`timescale 1ns/1ps
module tb_page_manager;
reg clk=0,rst=1,training=0,n=0,p=0,ready=1,valid=1,accept=0;
reg [2:0] count=4;
reg [1:0] displayed=3;
wire req,pending,missing,user_req;
wire [1:0] target;
always #5 clk=~clk;
cpr_page_manager dut(clk,rst,training,n,p,ready,count,valid,displayed,
                     accept,req,pending,target,missing,user_req);
task tick; begin @(negedge clk); end endtask
task check;
 input integer index,waiting,is_missing;
 begin
  if(target!==index[1:0] || pending!==waiting[0] || missing!==is_missing[0])
   $fatal(1,"page policy mismatch target=%0d pending=%b missing=%b expected=%0d/%0d/%0d",target,pending,missing,index,waiting,is_missing);
 end
endtask
task next;begin n=1;tick;n=0;tick;end endtask
task prev;begin p=1;tick;p=0;tick;end endtask
task ack;begin if(!req)$fatal(1,"no valid request to ACK");accept=1;tick;accept=0;tick;end endtask
initial begin
 repeat(3)tick;rst=0;tick;
 n=1;repeat(3)tick; // Held before training: entry must still select page 1.
 training=1;tick;check(1,1,0);repeat(4)tick;check(1,1,0);
 n=0;tick;next;check(2,1,0);next;check(3,1,0);next;check(0,1,0);
 prev;check(3,1,0);ack;check(3,0,0);
 n=1;p=1;tick;n=0;p=0;tick;check(3,0,0);
 next;check(0,1,0);displayed=0;
 // ACK of the old target and exit together must leave restore queued.
 accept=1;training=0;tick;accept=0;check(3,1,0);ack;check(3,0,0);
 ready=0;valid=0;training=1;tick;check(1,1,0);
 if(req)$fatal(1,"request accepted before catalog ready");
 repeat(4)tick;ready=1;count=1;tick;check(1,1,1);
 if(req)$fatal(1,"missing default silently clamped");
 next;check(0,1,0);ack;check(0,0,0);
 training=0;tick;check(0,1,0);ack; // no saved display -> page zero
 training=1;tick;count=0;tick;check(1,1,1);
 next;check(1,1,1); // empty catalog never underflows or starts a load
 rst=1;tick;rst=0;count=4;valid=1;displayed=2;tick;check(1,1,0);
 training=0;tick;check(2,1,0);
 $display("PASS: tb_page_manager");$finish;
end
initial begin #10000;$fatal(1,"TIMEOUT page manager");end
endmodule
