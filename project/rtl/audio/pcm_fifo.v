`timescale 1ns/1ps
//=============================================================================
// pcm_fifo.v —— PCM 帧异步 FIFO（48 bit：{R[23:0], L[23:0]}）
//-----------------------------------------------------------------------------
// 为什么音频这条链必须有一级"跨时钟"的缓冲（对应视频路径里的 SDRAM 帧缓存）：
//   * 写侧：SD 扇区读跑在 100 MHz（sd_card_clk），节奏是"来一整扇区 128 帧，
//     然后几百微秒没动静"，突发性极强；
//   * 读侧：I2S 播放跑在 12.288 MHz 音频时钟域，节奏是"每 256 拍取一帧"，
//     绝对均匀，一拍都不能断。
//   两者的瞬时速率比接近 ∞ : 1，靠任何"握手反压"都救不了，必须靠缓冲区把
//   突发磨平。1024 帧 = 21.3 ms @48 kHz，而读一个扇区只要约 0.2 ms，
//   余量 ~100 倍，正常播放不可能 underrun。
//
// 实现：Cummings 式格雷码指针异步 FIFO
//   * 指针用格雷码跨域，每次只有 1 bit 变化，不会出现多 bit 亚稳采样；
//   * 存储体是 1 写 1 读双口，TD 推成 BRAM（1024 深 × 48 bit；16 bit 时代是
//     ×32，加宽的那 16 bit 就是第二个声道的低 8 位 + 右声道多出来的 8 位）；
//   * 读侧是"寄存输出"，O_rd_valid 比 I_rd_en 晚一拍——播放侧按这个时序取数；
//   * 写侧给 O_wr_space，让 wav_reader 以"整扇区"为粒度决定要不要发下一个请求。
//
// 注意：O_rd_empty 是"读侧看到的空"，比真实空最多晚 2 拍（同步器延迟），
// 因此它只会"偏保守地晚一点变空"，绝不会让播放侧读到无效数据。
//=============================================================================
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

// 满：写指针 == 读指针"高两位取反"（Cummings 判满的等价形式，用**当前**指针）
//
// 注意不能用 W_wgray_next 来判断：W_wgray_next 由 W_wbin_next 算出，而
// W_wbin_next 里含 ~O_wr_full —— 那样 full 依赖 next、next 依赖 full，
// 会形成组合环。FIFO 一旦真的写满，环上就会振荡（ModelSim 报
// vsim-3601 iteration limit）。用当前指针判满既等价又没有环。
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
