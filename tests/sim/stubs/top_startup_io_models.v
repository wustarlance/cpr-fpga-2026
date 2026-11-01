`timescale 1ns/1ps
`include "include/global_def.v"
// Test-only boundary stimuli. Not vendor models or a physical HDMI/SDRAM test.

module sys_pll (
  refclk,
  reset,
  extlock,
  clk0_out,
  clk1_out,
  clk2_out 
);


  input refclk;
  input reset;
  output extlock;
  output clk0_out;
  output clk1_out;
  output clk2_out;
reg model_locked=0; reg sd_clock=0,mem_clock=0; always #5 sd_clock=~sd_clock; always #12.5 mem_clock=~mem_clock;
assign extlock = model_locked;
assign clk0_out = sd_clock;
assign clk1_out = mem_clock;
assign clk2_out = mem_clock;
endmodule

module video_pll (
  refclk,
  reset,
  extlock,
  clk0_out,
  clk1_out 
);


  input refclk;
  input reset;
  output extlock;
  output clk0_out;
  output clk1_out;
reg model_locked=0; reg pixel_clock=0,serial_clock=0; always #20 pixel_clock=~pixel_clock; always #4 serial_clock=~serial_clock;
assign extlock = model_locked;
assign clk0_out = pixel_clock;
assign clk1_out = serial_clock;
endmodule

module PLL_HDMI_AUDIO (
  refclk,
  reset,
  extlock,
  clk0_out,
  clk1_out,
  clk2_out 
);


  input refclk;
  input reset;
  output extlock;
  output clk0_out;
  output clk1_out;
  output clk2_out;
reg model_locked=0; reg audio_clock=0; always #40.667 audio_clock=~audio_clock;
assign extlock = model_locked;
assign clk0_out = 0;
assign clk1_out = 0;
assign clk2_out = audio_clock;
endmodule

module sd_card_top
#(
    parameter integer TOKEN_TIMEOUT_CYCLES = 10_000_000,
    parameter integer SPI_TIMEOUT_CYCLES = 1_000_000,
	parameter  SPI_LOW_SPEED_DIV = 248,         
    
    
    
	parameter  SPI_HIGH_SPEED_DIV = 1
)
(
	input            clk,
	input            rst,
    input            read_cancel,
    output           sd_sec_ready,
    output           sd_sec_read_error,
	output           SD_nCS,                    
	output           SD_DCLK,                   
	output           SD_MOSI,                   
	input            SD_MISO,                   
	output           sd_init_done,              
	input            sd_sec_read,               
	input[31:0]      sd_sec_read_addr,          
	output[7:0]      sd_sec_read_data,          
	output           sd_sec_read_data_valid,    
	output           sd_sec_read_end,           
	input            sd_sec_write,              
	input[31:0]      sd_sec_write_addr,         
	input[7:0]       sd_sec_write_data,         
	output           sd_sec_write_data_req,     
	output           sd_sec_write_end           
);


assign sd_sec_ready = 0;
assign sd_sec_read_error = 0;
assign SD_nCS = 0;
assign SD_DCLK = 0;
assign SD_MOSI = 0;
assign sd_init_done = 0;
assign sd_sec_read_data = 0;
assign sd_sec_read_data_valid = 0;
assign sd_sec_read_end = 0;
assign sd_sec_write_data_req = 0;
assign sd_sec_write_end = 0;
endmodule

module sd_card_bmp #(
    parameter [1:0] TRAINING_PAGE_INDEX = 2'd1,
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    
    parameter integer AUTO_DWELL_S      = 1,
    parameter integer RETRY_LIMIT       = 1,
    parameter integer LOAD_TIMEOUT_CYCLES = CLK_FREQ_HZ * 3,
    parameter integer READER_TIMEOUT_CYCLES = CLK_FREQ_HZ,
    parameter integer TOKEN_TIMEOUT_CYCLES = CLK_FREQ_HZ / 10,
    parameter integer SPI_TIMEOUT_CYCLES = CLK_FREQ_HZ / 100,
    parameter integer RECOVERY_GUARD_CYCLES = 32,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd4,
    parameter         SCALE_ENABLE     = 1'b0,
    parameter         BLUR_BACKGROUND  = 1'b0,
    parameter integer BG_BRIGHTNESS_NUM = 3,
    parameter integer BG_BRIGHTNESS_SHIFT = 2,
    parameter integer DST_WIDTH        = 640,
    parameter integer DST_HEIGHT       = 480
)(
    input                       clk,
    input                       rst,
    input                       key_next,
    input                       key_prev,
    input                       key_auto,
    input                       external_auto,
    input                       training_active,
    input                       training_next,
    input                       training_prev,
    output [11:0]               page_status,
    output [3:0]                state_code,
    output wire [2:0]            media_error,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output wire                  display_valid,
    output wire                 boot_load_done,

    input                       write_finish_toggle,
    output wire [1:0]            write_buf_idx,
    output wire [1:0]            disp_buf_idx,
    output wire                  publish_req,
    output wire                  publish_fade,
    input                       publish_done,

    output                      write_req,
    input                       write_req_ack,
    input                       pixel_ready,
    output                      write_en,
    output [31:0]               write_data,

    
    input                       sd_sec_ready,          
    input                       sd_sec_read_error,     
    input                       sd_init_done,          
    input  [7:0]                sd_sec_read_data,      
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,       
    output                      sd_sec_read,           
    output [31:0]               sd_sec_read_addr,      
    output                      sd_read_cancel         
);


assign page_status = 0;
assign state_code = 0;
assign media_error = 0;
assign display_valid = 0;
assign boot_load_done = 0;
assign write_buf_idx = 0;
assign disp_buf_idx = 0;
assign publish_req = 0;
assign publish_fade = 0;
assign write_req = 0;
assign write_en = 0;
assign write_data = 0;
assign sd_sec_read = 0;
assign sd_sec_read_addr = 0;
assign sd_read_cancel = 0;
endmodule

module frame_read_write
#
(
	parameter MEM_DATA_BITS          = 32,
	parameter READ_DATA_BITS         = 32,
	parameter WRITE_DATA_BITS        = 32,
	parameter ADDR_BITS              = 21,
	parameter BURST_BITS             = 9,
	parameter BURST_SIZE             = 256, 
    parameter WRITE_BURST_SIZE       = BURST_SIZE,
    parameter WRITE_TO_READ_GAP      = 0,
    parameter WRITE_RESTART_GAP      = 0,
	parameter WRITE_V_FLIP           = 1,      
	parameter FRAME_WIDTH            = 640,
	parameter FRAME_HEIGHT           = 480,
    parameter READ_INDEX_SYNCHRONOUS = 0,
    parameter DIAGNOSTIC_PAUSE_ENABLE = 0
) 
(
	input                            rst,                  
	input                            mem_clk,                    
	input							 Sdr_init_done,
	input							 Sdr_init_ref_vld,
    input							 Sdr_busy,
	
    
	output							 App_rd_en,
	output[ADDR_BITS - 1:0]			 App_rd_addr,
	input							 Sdr_rd_en,					 
	input[MEM_DATA_BITS - 1:0]		 Sdr_rd_dout,
	
	input                            read_clk,                   
	input                            read_req,                   
	output                           read_req_ack,               
	output                           read_finish,                
	input[ADDR_BITS - 1:0]           read_addr_0,                
	input[ADDR_BITS - 1:0]           read_addr_1,                
	input[ADDR_BITS - 1:0]           read_addr_2,                
	input[ADDR_BITS - 1:0]           read_addr_3,                
	input[1:0]                       read_addr_index,            
	input[ADDR_BITS - 1:0]           read_len,                   
	input                            read_en,                    
	output[READ_DATA_BITS  - 1:0]    read_data,                  
	
	output							 App_wr_en,
	output[ADDR_BITS - 1:0]			 App_wr_addr,
	output[MEM_DATA_BITS - 1:0]	 App_wr_din,
	output[3:0]						 App_wr_dm,
	
	
	input                            write_clk,                  
	input                            write_req,                  
	output                           write_req_ack,              
	output                           write_finish,               
	input[ADDR_BITS - 1:0]           write_addr_0,               
	input[ADDR_BITS - 1:0]           write_addr_1,               
	input[ADDR_BITS - 1:0]           write_addr_2,               
	input[ADDR_BITS - 1:0]           write_addr_3,               
	input[1:0]                       write_addr_index,           
	input[ADDR_BITS - 1:0]           write_len,                  
	input                            write_en,                   
	input[WRITE_DATA_BITS - 1:0]     write_data,                
    output frame_start, 
    output write_ready, 
    
    input diagnostic_pause,
    output probe_write_full, probe_write_empty, probe_read_full, probe_read_empty, probe_write_clear

);


assign App_rd_en = 0;
assign App_rd_addr = 0;
assign read_req_ack = read_req;
assign read_finish = 0;
assign read_data = 32'h21436500;
assign App_wr_en = 0;
assign App_wr_addr = 0;
assign App_wr_din = 0;
assign App_wr_dm = 0;
assign write_req_ack = 0;
assign write_finish = 0;
assign frame_start = 0;
assign write_ready = 0;
assign probe_write_full = 0;
endmodule

module sdram #(
    parameter REGISTER_READ_DATA = 0,
    parameter FORWARD_CLOCK_ODDR = 0
)(

    
    input   					Clk,
    input						Clk_sft,
    input						Rst,
    
    output 						Sdr_init_done,
    output						Sdr_init_ref_vld,
    output						Sdr_busy,
    
    input						App_wr_en,
	input [`ADDR_WIDTH-1:0]		App_wr_addr,  	
	input [`DM_WIDTH-1:0]		App_wr_dm,
	input [`DATA_WIDTH-1:0]		App_wr_din,	
    
    input 						App_rd_en,
	input [`ADDR_WIDTH-1:0]		App_rd_addr,
	output 						Sdr_rd_en,
	output [`DATA_WIDTH-1:0]	Sdr_rd_dout	
    
    
    
);


assign Sdr_init_done = 0;
assign Sdr_init_ref_vld = 0;
assign Sdr_busy = 0;
assign Sdr_rd_en = 0;
assign Sdr_rd_dout = 0;
endmodule

module cpr_overlay #(parameter UNCALIBRATED_PRESSURE = 0,
                     parameter PAGE_STATUS_ENABLE = 0,
                     parameter CHINESE_UI = 0)(
    input wire clk, rst, vs, de,
    input wire [23:0] rgb,
    input wire [1:0] mode,
    input wire [31:0] count,
    input wire [1:0] rate,
    input wire pause_warning, rotate_due, beat,
    input wire [1:0] depth_grade,
    input wire [15:0] interval_ms, pause_ms,
    input wire [31:0] rotate_remaining_ms,
    input wire [7:0] bpm,
    input wire bpm_valid, sensor_fault,
    input wire [1:0] brightness_level,
    input wire [2:0] contrast_level,
    input wire auto_running,
    input wire [11:0] page_status,
    
    
    input wire subtitle_en,
    output wire [23:0] out_rgb
);


assign out_rgb = rgb;
endmodule

module wav_audio_sd_top #(
    parameter integer MCLK_HZ                          = 12_288_000,
    parameter integer pcm_bits                         = 24,        
    parameter integer FIFO_DEPTH                       = 1024,      
    parameter integer FIFO_addr_bits                   = 10,        
    parameter integer ACR_N                            = 6144       
)(
    
    input  wire        I_sd_clk,
    input  wire        I_mclk,
    input  wire        I_video_clk,
    input  wire        I_sd_rst,          
    input  wire        I_mclk_rst,
    input  wire        I_video_rst,

    
    input  wire [2:0]  I_audio_sel,         
    input  wire        I_play,              
    input  wire        I_stop,              
    input  wire        I_mute,
    input  wire        I_loop,
    input  wire        I_heart_en,          

    
    input  wire        I_sd_init_done,
    input  wire        I_sd_sec_ready,      
    output wire [31:0] O_sd_sec_addr,
    output wire        O_sd_sec_read,
    input  wire [7:0]  I_sd_sec_data,
    input  wire        I_sd_sec_valid,
    input  wire        I_sd_sec_end,

    

    
    output wire                    O_audio_valid,
    output wire [pcm_bits-1:0]     O_audio_left_data,
    output wire [pcm_bits-1:0]     O_audio_right_data,
    output wire                    O_acr_valid,
    output wire [19:0]             O_acr_cts,
    output wire [19:0]             O_acr_n,

    
    output wire        O_wav_ready,
    output wire        O_wav_error,
    output wire [3:0]  O_wav_error_code,
    output wire [3:0]  O_wav_state,
    output wire [31:0] O_file_size,
    output wire [31:0] O_sample_rate,
    output wire [15:0] O_channels,
    output wire [15:0] O_bits,
    output wire [31:0] O_frame_total,
    output wire [31:0] O_play_pos,
    output wire        O_play_end,
    output wire [FIFO_addr_bits:0] O_buf_level,
    output wire        O_underrun
);


assign O_sd_sec_addr = 0;
assign O_sd_sec_read = 0;
assign O_audio_valid = 1'b1;
assign O_audio_left_data = 24'h123456;
assign O_audio_right_data = 24'h654321;
assign O_acr_valid = 1'b1;
assign O_acr_cts = 0;
assign O_acr_n = 0;
assign O_wav_ready = 0;
assign O_wav_error = 0;
assign O_wav_error_code = 0;
assign O_wav_state = 0;
assign O_file_size = 0;
assign O_sample_rate = 0;
assign O_channels = 0;
assign O_bits = 0;
assign O_frame_total = 0;
assign O_play_pos = 0;
assign O_play_end = 0;
assign O_buf_level = 0;
assign O_underrun = 0;
endmodule

module hdmi_1_4b_transmitter_core_wrapper#(
    parameter DEVICE            = "EG", 

    parameter HTOTAL            = 2200,
    parameter HSA               = 44,
    parameter HFP               = 88,
    parameter HBP               = 148,
    parameter HACTIVE           = 1920,
    parameter VTOTAL            = 1125,
    parameter VSA               = 5,
    parameter VFP               = 4,
    parameter VBP               = 36,
    parameter VACTIVE           = 1080,

    parameter VIDEO_TPG         = "Enable",
    parameter VIDEO_FORMAT      = "RGB",
    parameter VIDEO_VIC         = 16,

    parameter AUDIO_SAMPLE_RATE = "48K",

    parameter IIC_SCL_DIV       = 125
)(
    input wire       I_pixel_clk,
    input wire       I_rst,

    
    input wire       I_edid_read_trig,
    output wire      O_edid_read_valid,
    output wire[7:0] O_edid_read_data,

    
    input wire       I_axis_s_user,
    input wire       I_axis_s_valid,
    input wire       I_axis_s_last,
    input wire[23:0] I_axis_s_data,
    output wire      O_axis_s_ready,

    
    input wire       I_audio_valid,     
    input wire[23:0] I_audio_left_data, 
    input wire[23:0] I_audio_right_data,

    
    input wire       I_acr_valid,
    input wire[19:0] I_acr_cts,
    input wire[19:0] I_acr_n,

    
    output wire      O_video_locked,

    
    output wire      O_ddc_scl,
    inout wire       IO_ddc_sda,

    
    output wire[9:0] O_ch0_tmds_data,
    output wire[9:0] O_ch1_tmds_data,
    output wire[9:0] O_ch2_tmds_data,
    output wire[9:0] O_clk_tmds_data
);


assign O_edid_read_valid = 0;
assign O_edid_read_data = 0;
assign O_axis_s_ready = 1'b1;
assign O_video_locked = 0;
assign O_ddc_scl = 0;
assign O_ch0_tmds_data = 0;
assign O_ch1_tmds_data = 0;
assign O_ch2_tmds_data = 0;
assign O_clk_tmds_data = 0;
endmodule

module hdmi_phy_wrapper#(
    parameter DEVICE = "EG"
    )(
    input wire      I_pixel_clk,
    input wire      I_serial_clk,
    input wire      I_rst,

    input wire[9:0] I_tmds_channel_0,
    input wire[9:0] I_tmds_channel_1,
    input wire[9:0] I_tmds_channel_2,
    input wire[9:0] I_tmds_channel_clk,
    
    output wire     O_tmds_ch0_p,
    output wire     O_tmds_ch1_p,
    output wire     O_tmds_ch2_p,
    output wire     O_tmds_clk_p
);


assign O_tmds_ch0_p = 0;
assign O_tmds_ch1_p = 0;
assign O_tmds_ch2_p = 0;
assign O_tmds_clk_p = 0;
endmodule
