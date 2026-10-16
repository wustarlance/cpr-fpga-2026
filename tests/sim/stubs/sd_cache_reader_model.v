`timescale 1ns/1ps
// Byte transport is tested separately. This model controls catalogue/load
// completion timing so the scheduler's buffer ownership can be stressed.
module bmp_read_scaled #(parameter WAIT_TIMEOUT_CYCLES=100000000,
 parameter MAX_WIDTH=2048,MAX_HEIGHT=1536,DST_WIDTH=640,DST_HEIGHT=480)(
 input cancel,sd_sec_ready,sd_sec_read_error,
 output abort_sd,operation_error,output[2:0]error_code,
 input clk,rst, output reg ready,
 input scan_start, input [31:0] scan_start_sector,scan_max_sector,
 input [2:0] scan_target_count, output reg scan_done,scan_found_valid,
 output reg [31:0] scan_found_sector,output reg [2:0] scan_found_total,
 input load_start,input [31:0] load_sector,input sd_init_done,
 output [3:0] state_code,input [15:0] bmp_width,bmp_height,
 output write_req,input write_req_ack,output sd_sec_read,
 output [31:0] sd_sec_read_addr,input [7:0] sd_sec_read_data,
 input sd_sec_read_data_valid,sd_sec_read_end,
 output bmp_data_wr_en,output [23:0] bmp_data, input pixel_ready,output load_error);
 reg [9:0] remaining;
 reg [3:0] scan_step;
 assign state_code=ready?1:4;assign load_error=0;
 assign abort_sd=0;assign operation_error=0;assign error_code=0;
 assign write_req=!ready && scan_step==0 && remaining>490;assign sd_sec_read=0;assign sd_sec_read_addr=load_sector;
 assign bmp_data_wr_en=0;assign bmp_data=0;
 always @(posedge clk or posedge rst) begin
  if(rst)begin ready<=1;scan_done<=0;scan_found_valid<=0;
   scan_found_sector<=0;scan_found_total<=0;remaining<=0;scan_step<=0;end
  else begin
   scan_found_valid<=0;
   if(cancel)begin ready<=1;remaining<=0;end
   else if(scan_start)begin ready<=0;scan_step<=1;scan_done<=0;scan_found_total<=0;end
   else if(scan_step!=0)begin
    scan_step<=scan_step+1;
    if(scan_step==1||scan_step==3||scan_step==5||scan_step==7)begin scan_found_valid<=1;
     scan_found_sector<=((scan_step+1)/2)*100;scan_found_total<=scan_found_total+1;end
    if(scan_step==9)begin scan_done<=1;ready<=1;scan_step<=0;end
   end
   else if(load_start)begin ready<=0;remaining<=500;end
   else if(remaining!=0)begin remaining<=remaining-1;if(remaining==1)ready<=1;end
  end
 end
endmodule

module sd_card_top #(parameter TOKEN_TIMEOUT_CYCLES=10000000,
 parameter SPI_TIMEOUT_CYCLES=1000000)(
 input read_cancel,output sd_sec_ready,sd_sec_read_error,
 input clk,rst,output SD_nCS,SD_DCLK,SD_MOSI,input SD_MISO,
 output sd_init_done,input sd_sec_read,input[31:0]sd_sec_read_addr,
 output[7:0]sd_sec_read_data,output sd_sec_read_data_valid,sd_sec_read_end,
 input sd_sec_write,input[31:0]sd_sec_write_addr,input[7:0]sd_sec_write_data,
 output sd_sec_write_data_req,sd_sec_write_end);
 assign sd_sec_ready=!rst;assign sd_sec_read_error=0;
 assign sd_init_done=!rst;
 assign SD_nCS=1;assign SD_DCLK=0;assign SD_MOSI=1;
 assign sd_sec_read_data=0;assign sd_sec_read_data_valid=0;assign sd_sec_read_end=0;
 assign sd_sec_write_data_req=0;assign sd_sec_write_end=0;
endmodule
