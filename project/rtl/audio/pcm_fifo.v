`timescale 1ns/1ps
// PCM异步FIFO，隔离SD突发写入与MCLK域的固定节拍读取。
// 写入宽度由WIDTH指定，音频通路使用48位{R[23:0],L[23:0]}。
// Gray指针经两级同步跨域；存储体为一写一读，读数据寄存输出。
// O_rd_valid相对接受的读请求晚一拍，O_wr_space供reader按扇区预留空间。
// 空满及水位使用本域指针与同步后的对端指针，解除空满有同步延迟。
// 1024帧在48 kHz下约21.3 ms；SD服务间隔超过缓冲时仍会欠载。
module pcm_fifo #(
    parameter integer WIDTH = 32,
    parameter integer DEPTH = 1024,
    parameter integer ADDR_DEPTH    = 10       // = log2(DEPTH)，显式给出，不依赖 $clog2
)(
    /* ---- 写侧（SD 时钟域） ---- */
    input  wire             I_wclk,
    input  wire             I_wrst,
    input  wire             I_wr_en,
    input  wire [WIDTH-1:0] I_wr_data,
    output wire             O_wr_full,
    output wire [ADDR_DEPTH:0]      O_wr_space,   // 还能写几个字

    /* ---- 读侧（像素/音频时钟域） ---- */
    input  wire             I_rclk,
    input  wire             I_rrst,
    input  wire             I_rd_en,
    output reg  [WIDTH-1:0] O_rd_data,    // 寄存输出：I_rd_en 之后一拍有效
    output reg              O_rd_valid,
    output wire             O_rd_empty,
    output wire [ADDR_DEPTH:0]      O_rd_level,   // 里面还有几个字
    output reg  [ADDR_DEPTH:0]      O_rd_max      // 观察到的最大水位（看余量用）
);

localparam [ADDR_DEPTH:0] DEPTH_C = DEPTH;

//--------------------------------------------------------------------------
// 存储体：1 写 1 读
//--------------------------------------------------------------------------
reg [WIDTH-1:0] S_mem [0:DEPTH-1];

//--------------------------------------------------------------------------
// 指针
//--------------------------------------------------------------------------
reg  [ADDR_DEPTH:0] S_wbin, S_wgray;
reg  [ADDR_DEPTH:0] S_rbin, S_rgray;

wire [ADDR_DEPTH:0] W_wbin_next  = S_wbin + {{ADDR_DEPTH{1'b0}}, (I_wr_en & ~O_wr_full)};
wire [ADDR_DEPTH:0] W_wgray_next = (W_wbin_next >> 1) ^ W_wbin_next;
wire [ADDR_DEPTH:0] W_rbin_next  = S_rbin + {{ADDR_DEPTH{1'b0}}, (I_rd_en & ~O_rd_empty)};
wire [ADDR_DEPTH:0] W_rgray_next = (W_rbin_next >> 1) ^ W_rbin_next;

//--------------------------------------------------------------------------
// 指针跨域同步（两级）
//--------------------------------------------------------------------------
reg [ADDR_DEPTH:0] S_rgray_w1, S_rgray_w2;   // 读指针 -> 写域
reg [ADDR_DEPTH:0] S_wgray_r1, S_wgray_r2;   // 写指针 -> 读域

always @(posedge I_wclk or posedge I_wrst) begin
    if (I_wrst) begin
        S_rgray_w1 <= {(ADDR_DEPTH+1){1'b0}};
        S_rgray_w2 <= {(ADDR_DEPTH+1){1'b0}};
    end
    else begin
        S_rgray_w1 <= S_rgray;
        S_rgray_w2 <= S_rgray_w1;
    end
end

always @(posedge I_rclk or posedge I_rrst) begin
    if (I_rrst) begin
        S_wgray_r1 <= {(ADDR_DEPTH+1){1'b0}};
        S_wgray_r2 <= {(ADDR_DEPTH+1){1'b0}};
    end
    else begin
        S_wgray_r1 <= S_wgray;
        S_wgray_r2 <= S_wgray_r1;
    end
end

//--------------------------------------------------------------------------
// 格雷码 → 二进制（算水位用，组合逻辑很浅）
//--------------------------------------------------------------------------
function [ADDR_DEPTH:0] gray2bin;
    input [ADDR_DEPTH:0] g;
    integer i;
    begin
        gray2bin[ADDR_DEPTH] = g[ADDR_DEPTH];
        for (i = ADDR_DEPTH-1; i >= 0; i = i - 1)
            gray2bin[i] = gray2bin[i+1] ^ g[i];
    end
endfunction

wire [ADDR_DEPTH:0] W_rbin_in_w = gray2bin(S_rgray_w2);
wire [ADDR_DEPTH:0] W_wbin_in_r = gray2bin(S_wgray_r2);

// 当前写Gray指针等于同步读指针高两位取反时为满。
// 不使用next指针判满：next本身依赖O_wr_full，会形成组合环。
assign O_wr_full  = (S_wgray == {~S_rgray_w2[ADDR_DEPTH:ADDR_DEPTH-1], S_rgray_w2[ADDR_DEPTH-2:0]});
assign O_wr_space = DEPTH_C - (S_wbin - W_rbin_in_w);

// 空
assign O_rd_empty = (S_rgray == S_wgray_r2);
assign O_rd_level = W_wbin_in_r - S_rbin;   // 写指针 - 读指针 = 现有数量

//--------------------------------------------------------------------------
// 写侧
//--------------------------------------------------------------------------
always @(posedge I_wclk or posedge I_wrst) begin
    if (I_wrst) begin
        S_wbin  <= {(ADDR_DEPTH+1){1'b0}};
        S_wgray <= {(ADDR_DEPTH+1){1'b0}};
    end
    else begin
        S_wbin  <= W_wbin_next;
        S_wgray <= W_wgray_next;
    end
end

always @(posedge I_wclk) begin
    if (I_wr_en && !O_wr_full)
        S_mem[S_wbin[ADDR_DEPTH-1:0]] <= I_wr_data;
end

//--------------------------------------------------------------------------
// 读侧
//--------------------------------------------------------------------------
always @(posedge I_rclk or posedge I_rrst) begin
    if (I_rrst) begin
        S_rbin     <= {(ADDR_DEPTH+1){1'b0}};
        S_rgray    <= {(ADDR_DEPTH+1){1'b0}};
        O_rd_data  <= {WIDTH{1'b0}};
        O_rd_valid <= 1'b0;
        O_rd_max   <= {(ADDR_DEPTH+1){1'b0}};
    end
    else begin
        S_rbin  <= W_rbin_next;
        S_rgray <= W_rgray_next;

        if (I_rd_en && !O_rd_empty) begin
            O_rd_data  <= S_mem[S_rbin[ADDR_DEPTH-1:0]];
            O_rd_valid <= 1'b1;
        end
        else begin
            O_rd_valid <= 1'b0;
        end

        if (O_rd_level > O_rd_max)
            O_rd_max <= O_rd_level;
    end
end

endmodule
