`timescale 1ns/1ps
// SD public sector/byte interface model. It deliberately does not replace the
// product BMP parser, scheduler, frame publisher, or SDRAM writer FSM.
module sd_card_top #(parameter PAGE_COLOR=0, parameter TOKEN_TIMEOUT_CYCLES=10000000,
 parameter SPI_TIMEOUT_CYCLES=1000000)(
 input clk,rst,read_cancel,output sd_sec_ready,sd_sec_read_error,
 output SD_nCS,SD_DCLK,SD_MOSI,input SD_MISO,
 output sd_init_done,input sd_sec_read,input[31:0]sd_sec_read_addr,
 output reg[7:0]sd_sec_read_data,output reg sd_sec_read_data_valid,sd_sec_read_end,
 input sd_sec_write,input[31:0]sd_sec_write_addr,input[7:0]sd_sec_write_data,
 output sd_sec_write_data_req,sd_sec_write_end);
 integer image_count=4;
 integer fault_kind=0,fail_budget=0,fail_sector=1,only_transaction=0;
 integer transactions=0,position=0,age=0,chosen=0;
 reg busy=0,holdoff=0,failed=0;
 reg[31:0]address;
 assign sd_init_done=!rst;
 assign sd_sec_ready=!rst&&!busy&&!holdoff;
 assign sd_sec_read_error=failed;
 assign SD_nCS=!busy;assign SD_DCLK=0;assign SD_MOSI=1;
 assign sd_sec_write_data_req=0;assign sd_sec_write_end=0;
 function[7:0]file_byte;
  input integer p;input[31:0]lba;
  begin
   file_byte=0;
   case(p)
    0:file_byte="B";1:file_byte="M";2:file_byte=78;
    10:file_byte=54;14:file_byte=40;18:file_byte=4;22:file_byte=2;
    26:file_byte=1;28:file_byte=24;
    default:if(p>=54&&p<78)file_byte=(PAGE_COLOR ? (8'h20+lba*8'h30) : (lba==0?8'h20:8'h80))+(p-54);
   endcase
   if(lba>=image_count)file_byte=0;
  end
 endfunction
 always @(posedge clk or posedge rst)begin
  if(rst)begin busy<=0;holdoff<=0;failed<=0;sd_sec_read_data_valid<=0;
   sd_sec_read_end<=0;transactions<=0;position<=0;age<=0;chosen<=0;address<=0;end
  else begin
   sd_sec_read_data_valid<=0;sd_sec_read_end<=0;failed<=0;
   if(!sd_sec_read)holdoff<=0;
   if(read_cancel)begin busy<=0;holdoff<=1;end
   else if(!busy&&!holdoff&&sd_sec_read)begin
    busy<=1;position<=0;age<=0;address<=sd_sec_read_addr;
    transactions<=transactions+1;
    if(fail_budget!=0 && sd_sec_read_addr==fail_sector &&
       (only_transaction==0||transactions+1==only_transaction))begin
     chosen<=fault_kind;
     if(fail_budget>0)fail_budget<=fail_budget-1;
    end else chosen<=0;
   end else if(busy)begin
    age<=age+1;
    if(chosen==1)begin
     if(age==40)begin busy<=0;holdoff<=1;failed<=1;sd_sec_read_end<=1;end
    end else if(chosen==3 && position>=60)begin
     // No end or error: the reader's progress watchdog must cancel this.
    end else begin
     sd_sec_read_data<=chosen==4&&position==0 ? 8'h00 : file_byte(position,address);
     sd_sec_read_data_valid<=1;position<=position+1;
     if(position==511||(chosen==2&&position==31))begin
      busy<=0;holdoff<=1;sd_sec_read_end<=1;
     end
    end
   end
  end
 end
endmodule
