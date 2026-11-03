`timescale 1ns/1ps
//=============================================================================
// 首张教程就绪前，用 BRAM 位图输出静态 LOGO。
// gen_splash_rom.py 从本文件读取三个窗口参数，生成 2 bit/像素的四级灰度 ROM。
// 每字存四像素；地址寄存器和 ROM 输出各一拍，因此地址提前两个像素。
// 窗口裁剪用于控制 BRAM 占用，窗口外输出黑色。
// 首次可见时间还取决于 FPGA 配置和显示器锁定，需实板测量。
module splash_boot (
    input  wire        clk,      // video_clk（25 MHz）
    input  wire        rst,      // rst_video，高有效
    input  wire        vs,       // 与像素流同拍的场同步；极性无关，跳变即认
    input  wire        de,       // 有效像素使能（每行恰 640 拍）
    input  wire        hide,     // 1 = 已经有图可上屏，关掉开机画面
    output wire [23:0] rgb,      // 开机画面像素（窗口外为纯黑）
    output reg         active    // 开机画面正在接管输出；只在场消隐交棒
);

// 视频复位释放后至少保持 DWELL_CYCLES；25 MHz 下默认 3 s。
parameter integer DWELL_CYCLES = 75_000_000;

reg [26:0] dwell_cnt;
wire       dwell_done = (dwell_cnt >= DWELL_CYCLES);

always @(posedge clk or posedge rst) begin
    if (rst)                     dwell_cnt <= 27'd0;
    else if (!dwell_done)        dwell_cnt <= dwell_cnt + 27'd1;
end

// 三个窗口（gen_splash_rom.py 从这里解析；W 必须是 4 的整数倍 = 4 像素/字）
localparam [9:0] W1_X0 = 10'd256;
localparam [9:0] W1_Y0 = 10'd83;
localparam [9:0] W1_W  = 10'd136;
localparam [9:0] W1_H  = 10'd154;
localparam [9:0] W2_X0 = 10'd176;
localparam [9:0] W2_Y0 = 10'd264;
localparam [9:0] W2_W  = 10'd288;
localparam [9:0] W2_H  = 10'd62;
localparam [9:0] W3_X0 = 10'd280;
localparam [9:0] W3_Y0 = 10'd425;
localparam [9:0] W3_W  = 10'd80;
localparam [9:0] W3_H  = 10'd22;

//-----------------------------------------------------------------------------
// 像素坐标：从 vs/de 自己数，不碰上游时序模块
//-----------------------------------------------------------------------------
reg        vs_q;
reg [9:0]  px;
reg [9:0]  py;
wire       vs_edge = (vs_q != vs);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        vs_q <= 1'b0;
        px   <= 10'd0;
        py   <= 10'd0;
    end else begin
        vs_q <= vs;
        if (vs_edge) begin
            px <= 10'd0;
            py <= 10'd0;
        end else if (de) begin
            if (px == 10'd639) begin
                px <= 10'd0;
                py <= (py == 10'd479) ? 10'd0 : py + 10'd1;
            end else begin
                px <= px + 10'd1;
            end
        end
    end
end

//-----------------------------------------------------------------------------
// 三个窗口：窗口模块算地址 -> ROM 出字 -> 窗口模块取像素
//-----------------------------------------------------------------------------
wire [12:0] a1, a2, a3;
wire [8:0]  d1, d2, d3;   // ROM 输出 9 bit，只用到低 8 bit
wire [1:0]  p1, p2, p3;
wire        in1, in2, in3;

splash_window #(.X0(W1_X0), .Y0(W1_Y0), .W(W1_W), .H(W1_H)) u_win1 (
    .clk(clk), .rst(rst), .px(px), .py(py), .dout(d1),
    .addr(a1), .pix(p1), .in_win(in1));

splash_window #(.X0(W2_X0), .Y0(W2_Y0), .W(W2_W), .H(W2_H)) u_win2 (
    .clk(clk), .rst(rst), .px(px), .py(py), .dout(d2),
    .addr(a2), .pix(p2), .in_win(in2));

splash_window #(.X0(W3_X0), .Y0(W3_Y0), .W(W3_W), .H(W3_H)) u_win3 (
    .clk(clk), .rst(rst), .px(px), .py(py), .dout(d3),
    .addr(a3), .pix(p3), .in_win(in3));

splash_rom_w1 u_rom1 (.clk(clk), .addr(a1), .data(d1));
splash_rom_w2 u_rom2 (.clk(clk), .addr(a2), .data(d2));
splash_rom_w3 u_rom3 (.clk(clk), .addr(a3), .data(d3));

// 4 级灰度：0 → 黑，1 → 0x55，2 → 0xAA，3 → 白
function [7:0] gray_of(input [1:0] v);
    begin
        case (v)
            2'd1:    gray_of = 8'h55;
            2'd2:    gray_of = 8'haa;
            2'd3:    gray_of = 8'hff;
            default: gray_of = 8'h00;
        endcase
    end
endfunction

wire [1:0] pix    = in1 ? p1 : (in2 ? p2 : (in3 ? p3 : 2'd0));
wire [7:0] gray   = gray_of(pix);
wire       shaded = in1 | in2 | in3;

assign rgb    = shaded ? {gray, gray, gray} : 24'h000000;
// Dwell is a minimum SHOW time, never a delay before showing the BRAM logo.
// Switch only in vertical blanking, so a media SOF cannot contain half a logo.
always @(posedge clk or posedge rst) begin
    if (rst) active <= 1'b1;
    else if (!hide || !dwell_done) active <= 1'b1;
    else if (vs_edge && !de) active <= 1'b0;
end

endmodule

//=============================================================================
// splash_window —— 一个贴图窗口的取址与取像素
//   地址提前两个像素（见文件头"取图节奏"），像素按 4 像素/字节取 2 bit。
//=============================================================================
module splash_window #(
    parameter [9:0] X0 = 10'd0,
    parameter [9:0] Y0 = 10'd0,
    parameter [9:0] W  = 10'd8,
    parameter [9:0] H  = 10'd1
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [9:0]  px,
    input  wire [9:0]  py,
    input  wire [8:0]  dout,
    output wire [12:0] addr,
    output wire [1:0]  pix,
    output wire        in_win
);
    localparam [9:0] WPR = W >> 2;              // 每行字数（4 像素/字）

    wire        in_row  = (py >= Y0) && (py < Y0 + H);
    wire [9:0]  dy      = py - Y0;
    wire [9:0]  dx      = px - X0;              // 当前像素：判是否在窗口内
    wire [9:0]  dx_n    = (px + 10'd2) - X0;    // 提前两拍的像素：取址用
    wire [19:0] off     = dy * WPR;
    wire        addr_ok = in_row && (dx_n < W);
    wire [19:0] sum     = off + {12'd0, dx_n[9:2]};   // 20 bit 内加，不扩位
    wire [23:0] addr_int= addr_ok ? {4'd0, sum} : 24'd0;

    // 地址每拍都更新：从 px = X0-2 起 addr_ok 成立，正好赶上两级寄存器，
    // 所以不需要"消隐期对齐行首"的特殊处理。
    reg [12:0] addr_q;
    always @(posedge clk or posedge rst) begin
        if (rst) addr_q <= 13'd0;
        else     addr_q <= addr_int[12:0];
    end

    assign addr   = addr_q;
    assign in_win = in_row && (dx < W);
    assign pix    = dout[7 - {dx[1:0], 1'b0} -: 2];
endmodule
