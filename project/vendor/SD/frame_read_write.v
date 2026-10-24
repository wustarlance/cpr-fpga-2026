`timescale 1ns/1ps
module frame_read_write
#
(
	parameter MEM_DATA_BITS          = 32,
	parameter READ_DATA_BITS         = 32,
	parameter WRITE_DATA_BITS        = 32,
	parameter ADDR_BITS              = 21,
	parameter BURST_BITS             = 9,//
	parameter BURST_SIZE             = 256, // read burst and backwards-compatible write default
    parameter WRITE_BURST_SIZE       = BURST_SIZE,
    parameter WRITE_TO_READ_GAP      = 0,
    parameter WRITE_RESTART_GAP      = 0,
	parameter WRITE_V_FLIP           = 1,      // 1: vertical flip when writing TF/BMP frame into SDRAM
	parameter FRAME_WIDTH            = 640,
	parameter FRAME_HEIGHT           = 480,
    parameter READ_INDEX_SYNCHRONOUS = 0,
    parameter DIAGNOSTIC_PAUSE_ENABLE = 0
) 
(
	input                            rst,                  
	input                            mem_clk,                    // external memory controller user interface clock
	input							 Sdr_init_done,
	input							 Sdr_init_ref_vld,
    input							 Sdr_busy,
	
    /*
    output                           rd_burst_req,               // to external memory controller,send out a burst read request
	output[BURST_BITS - 1:0]         rd_burst_len,               // to external memory controller,data length of the burst read request, not bytes
	output[ADDR_BITS - 1:0]          rd_burst_addr,              // to external memory controller,base address of the burst read request 
	input                            rd_burst_data_valid,        // from external memory controller,read data valid 
	input[MEM_DATA_BITS - 1:0]       rd_burst_data,              // from external memory controller,read request data
	input                            rd_burst_finish,            // from external memory controller,burst read finish
	*/
	output							 App_rd_en,
	output[ADDR_BITS - 1:0]			 App_rd_addr,
	input							 Sdr_rd_en,					 //read_data_valid
	input[MEM_DATA_BITS - 1:0]		 Sdr_rd_dout,
	
	input                            read_clk,                   // data read module clock
	input                            read_req,                   // data read module read request,keep '1' until read_req_ack = '1'
	output                           read_req_ack,               // data read module read request response
	output                           read_finish,                // data read module read request finish
	input[ADDR_BITS - 1:0]           read_addr_0,                // data read module read request base address 0, used when read_addr_index = 0
	input[ADDR_BITS - 1:0]           read_addr_1,                // data read module read request base address 1, used when read_addr_index = 1
	input[ADDR_BITS - 1:0]           read_addr_2,                // data read module read request base address 1, used when read_addr_index = 2
	input[ADDR_BITS - 1:0]           read_addr_3,                // data read module read request base address 1, used when read_addr_index = 3
	input[1:0]                       read_addr_index,            // select valid base address from read_addr_0 read_addr_1 read_addr_2 read_addr_3
	input[ADDR_BITS - 1:0]           read_len,                   // data read module read request data length
	input                            read_en,                    // data read module read request for one data, read_data valid next clock
	output[READ_DATA_BITS  - 1:0]    read_data,                  // read data
	/*
	output                           wr_burst_req,               // to external memory controller,send out a burst write request
	output[BURST_BITS - 1:0]         wr_burst_len,               // to external memory controller,data length of the burst write request, not bytes
	output[ADDR_BITS - 1:0]          wr_burst_addr,              // to external memory controller,base address of the burst write request 
	input                            wr_burst_data_req,          // from external memory controller,write data request ,before data 1 clock
	output[MEM_DATA_BITS - 1:0]      wr_burst_data,              // to external memory controller,write data
	input                            wr_burst_finish,            // from external memory controller,burst write finish
	*/
	output							 App_wr_en,
	output[ADDR_BITS - 1:0]			 App_wr_addr,
	output[MEM_DATA_BITS - 1:0]	 App_wr_din,
	output[3:0]						 App_wr_dm,
	
	//
	input                            write_clk,                  // data write module clock
	input                            write_req,                  // data write module write request,keep '1' until read_req_ack = '1'
	output                           write_req_ack,              // data write module write request response
	output                           write_finish,               // data write module write request finish
	input[ADDR_BITS - 1:0]           write_addr_0,               // data write module write request base address 0, used when write_addr_index = 0
	input[ADDR_BITS - 1:0]           write_addr_1,               // data write module write request base address 1, used when write_addr_index = 1
	input[ADDR_BITS - 1:0]           write_addr_2,               // data write module write request base address 1, used when write_addr_index = 2
	input[ADDR_BITS - 1:0]           write_addr_3,               // data write module write request base address 1, used when write_addr_index = 3
	input[1:0]                       write_addr_index,           // select valid base address from write_addr_0 write_addr_1 write_addr_2 write_addr_3
	input[ADDR_BITS - 1:0]           write_len,                  // data write module write request data length
	input                            write_en,                   // data write module write request for one data
	input[WRITE_DATA_BITS - 1:0]     write_data,                // write data
    output frame_start, // memory-domain reader frame boundary
    output write_ready, // write FIFO has space
    // Passive diagnostic taps: flags retain their native FIFO clock domain.
    input diagnostic_pause,
    output probe_write_full, probe_write_empty, probe_read_full, probe_read_empty, probe_write_clear

);
wire[BURST_BITS - 1:0]                           wrusedw;                    // write used words
wire[BURST_BITS - 1:0]                           rdusedw;                    // read used words

wire 								 App_rd_busy;
wire								 App_wr_busy;

wire                                 read_fifo_aclr;             // fifo Asynchronous clear
wire                                 write_fifo_aclr;            // fifo Asynchronous clear
assign probe_write_clear=write_fifo_aclr;

wire O_wr_busy;
wire write_fifo_full;
assign probe_write_full = write_fifo_full;
assign write_ready = ~write_fifo_full;
wire O_rd_busy;
wire read_urgent;

// D115 exploratory tail guard: it blocks only NEW read transactions.
// It does not interrupt a write or a four-word group. Default0 is bypass.
localparam WRITE_GAP_BITS = (WRITE_TO_READ_GAP<1) ? 1 : $clog2(WRITE_TO_READ_GAP+1);
reg [WRITE_GAP_BITS-1:0] write_tail;
always @(posedge mem_clk or posedge rst) begin
    if(rst) write_tail<=0;
    else if(App_wr_en) write_tail<=WRITE_TO_READ_GAP;
    else if(write_tail!=0) write_tail<=write_tail-1'b1;
end
wire pause_admission=DIAGNOSTIC_PAUSE_ENABLE ? diagnostic_pause : 1'b0;
assign App_wr_busy = O_wr_busy | (write_tail!=0) | pause_admission;
// Give a low display FIFO priority before starting another write burst.
assign App_rd_busy = O_rd_busy | read_urgent | pause_admission;
assign App_wr_dm = 4'b0000;

//instantiate an asynchronous FIFO 
wfifo_32_32_512 write_buf
	(
	.clkr                      	(mem_clk                  ),          // Read side clock
	.clkw                      	(write_clk                ),          // Write side clock
	.rst                       	(write_fifo_aclr          ),          // Asynchronous clear
	.we                      	(write_en                 ),          // Write Request
	.re                      	(App_wr_en        		  ),          // Read Request
	.di                       	(write_data               ),          // Input Data
	.empty_flag                 (probe_write_empty        ),          // Read side Empty flag
	.full_flag                  (write_fifo_full          ),          // Write side Full flag
	.wrusedw                	(              	  		  ),          // Read Used Words
	.rdusedw                	(rdusedw                  ),          // Write Used Words
	.dout                       (App_wr_din		          )
);

frame_fifo_write
#
(
	.MEM_DATA_BITS              (MEM_DATA_BITS            ),
	.ADDR_BITS                  (ADDR_BITS                ),
	.BURST_BITS                 (BURST_BITS               ),
	.BURST_SIZE                 (WRITE_BURST_SIZE         ),
    .WRITE_RESTART_GAP          (WRITE_RESTART_GAP        ),
	.WRITE_V_FLIP               (WRITE_V_FLIP             ),
	.FRAME_WIDTH                (FRAME_WIDTH              ),
	.FRAME_HEIGHT               (FRAME_HEIGHT             )
) 
frame_fifo_write_m0              
(  
	.rst                        (rst                      ),
	.mem_clk                    (mem_clk                  ),
    .Sdr_init_done				(Sdr_init_done),
	.Sdr_init_ref_vld			(Sdr_init_ref_vld),
    .Sdr_busy					(Sdr_busy),
	.App_rd_busy				(App_rd_busy),
    .O_wr_busy					(O_wr_busy),
	
	.App_wr_en					(App_wr_en),
    .App_wr_addr				(App_wr_addr),
	.write_req                  (write_req                ),
	.write_req_ack              (write_req_ack            ),
	.write_finish               (write_finish             ),
	.write_addr_0               (write_addr_0             ),
	.write_addr_1               (write_addr_1             ),
	.write_addr_2               (write_addr_2             ),
	.write_addr_3               (write_addr_3             ),
	.write_addr_index           (write_addr_index         ),    
	.write_len                  (write_len                ),
	.fifo_aclr                  (write_fifo_aclr          ),
	.rdusedw                 	(rdusedw                  )
);

//instantiate an asynchronous FIFO 
rfifo_32_32_512 read_buf
	(
	.clkr                     	(read_clk                   ),          // Read side clock
	.clkw                     	(mem_clk                    ),          // Write side clock
	.rst                      	(read_fifo_aclr             ),          // Asynchronous clear
	.we                     	(Sdr_rd_en       			),          // Write Request
	.re                     	(read_en                    ),          // Read Request
	.di                      	(Sdr_rd_dout                ),          // Input Data
	.empty_flag                 (probe_read_empty         ),          // Read side Empty flag
	.full_flag                  (probe_read_full          ),          // Write side Full flag
	.wrusedw                	(wrusedw         	  	  		 ),          // Read Used Words
	.rdusedw                	(                  			 ),          // Write Used Words
	.dout						(read_data                  )
);

frame_fifo_read
#
(
	.MEM_DATA_BITS              (MEM_DATA_BITS            ),
	.ADDR_BITS                  (ADDR_BITS                ),
	.BURST_BITS                 (BURST_BITS               ),
	.BURST_SIZE                 (BURST_SIZE               ),
    .READ_INDEX_SYNCHRONOUS     (READ_INDEX_SYNCHRONOUS) 
)
frame_fifo_read_m0
(
	.rst                        (rst                      ),
	.mem_clk                    (mem_clk                  ),
    .Sdr_init_done				(Sdr_init_done),
	.Sdr_init_ref_vld			(Sdr_init_ref_vld),
    .Sdr_busy					(Sdr_busy),
    .Sdr_rd_en					(Sdr_rd_en),
	.App_wr_busy				(App_wr_busy),
    .O_rd_busy					(O_rd_busy),
	
    .App_rd_en					(App_rd_en),
    .App_rd_addr				(App_rd_addr),
	.read_req                   (read_req                 ),
    .frame_start                (frame_start),
    .read_urgent                (read_urgent),
	.read_req_ack               (read_req_ack             ),
	.read_finish                (read_finish              ),
	.read_addr_0                (read_addr_0              ),
	.read_addr_1                (read_addr_1              ),
	.read_addr_2                (read_addr_2              ),
	.read_addr_3                (read_addr_3              ),
	.read_addr_index            (read_addr_index          ),    
	.read_len                   (read_len                 ),
	.fifo_aclr                  (read_fifo_aclr           ),
	.wrusedw                	(wrusedw                  )
);

endmodule
