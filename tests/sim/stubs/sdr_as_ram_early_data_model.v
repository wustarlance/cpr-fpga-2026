`timescale 1ns/1ps
// Explicit user-interface timing model for actual-wrapper/FIFO regressions.
// This stub does not simulate the encrypted controller or physical SDRAM.
module sdr_as_ram #(parameter self_refresh_open=1, parameter EARLY_DATA=0)(
    input wire Sdr_clk,Sdr_clk_sft,Rst,App_ref_req,
    output wire Sdr_init_done,Sdr_init_ref_vld,Sdr_busy,
    input wire App_wr_en,input wire [20:0] App_wr_addr,
    input wire [3:0] App_wr_dm,input wire [31:0] App_wr_din,
    input wire App_rd_en,input wire [20:0] App_rd_addr,
    output wire Sdr_rd_en,output reg [31:0] Sdr_rd_dout,
    output wire SDRAM_CLK,SDR_RAS,SDR_CAS,SDR_WE,
    output wire [1:0] SDR_BA,output wire [10:0] SDR_ADDR,
    output wire [3:0] SDR_DM,inout wire [31:0] SDR_DQ
);
    reg [9:0] valid_pipe;
    reg [20:0] addresses[0:9];
    reg [31:0] memory[0:5119];
    reg [3:0] init_count;
    integer i;
    assign Sdr_init_done=init_count==4;
    assign Sdr_init_ref_vld=0;
    assign Sdr_busy=App_rd_en|App_wr_en;
    assign Sdr_rd_en=valid_pipe[9];
    assign SDRAM_CLK=Sdr_clk_sft;
    assign {SDR_RAS,SDR_CAS,SDR_WE,SDR_BA,SDR_ADDR,SDR_DM}=0;
    always @(posedge Sdr_clk or posedge Rst) begin
        if(Rst) begin
            valid_pipe<=0;init_count<=0;Sdr_rd_dout<=0;
            for(i=0;i<10;i=i+1) addresses[i]<=0;
        end else begin
            if(init_count!=4)init_count<=init_count+1'b1;
            valid_pipe<={valid_pipe[8:0],App_rd_en};
            addresses[0]<=App_rd_addr;
            for(i=1;i<10;i=i+1)addresses[i]<=addresses[i-1];
            if(App_wr_en && App_rd_en)$fatal(1,"Overlapping read and write");
            if(App_wr_en)begin
                if(App_wr_addr>=5120 || App_wr_dm!=0)$fatal(1,"Invalid model write");
                memory[App_wr_addr]<=App_wr_din;
            end
            if(EARLY_DATA)begin
                if(valid_pipe[7]) Sdr_rd_dout<=memory[addresses[7]];
            end else begin
                if(valid_pipe[8]) Sdr_rd_dout<=memory[addresses[8]];
            end
        end
    end
endmodule
module EG_PHY_SDRAM_2M_32(
    input wire clk,ras_n,cas_n,we_n,input wire [10:0] addr,
    input wire [1:0] ba,inout wire [31:0] dq,
    input wire cs_n,dm0,dm1,dm2,dm3,cke
); endmodule
