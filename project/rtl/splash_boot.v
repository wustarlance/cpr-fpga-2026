`timescale 1ns/1ps
//=============================================================================
// splash_boot.v —— 上电开机画面（第一张图能上屏之前显示）
//-----------------------------------------------------------------------------
// 为什么要有它
//   上电后要先 SD 初始化（50~100 ms）再扫卡（4 张图 1.87 s）才载入第 1 页，
//   这段时间屏幕一直是深蓝底（top 里那个 24'h102030），看起来像"没反应"。
//   这里在第一张图可上屏之前，把一张静态开机画面（logo + 标题 + "加载中..."）
//   接到像素通路上，上电 0.2 s 内就有画面。
//
// 数据从哪来
//   图不是画出来的，是**存在 BRAM 里的位图**：tools/gen_splash_rom.py 把
//   640x480 的 PNG 量化成 4 级灰度（2 bit/像素），按下面三个窗口裁剪，
//   生成 splash_rom_w1/w2/w3.v 三个 ROM。
//   窗口位置就写在本文件的 localparam 里，那个脚本**从本文件解析**这几个值
//   （和 burn_wav.py 从 wav_track_select.v 解析 LBA 是同一个套路），
//   所以改窗口只改这里，不存在两处不一致。
//
// 为什么拆三个窗口、为什么 2 bit
//   EG4S20 的 BRAM 只有 9Kb（1,024x9）和 32Kb（16 位宽，TD 推断时用不到），
//   而 9Kb 块塞宽字浪费极大：实测 64 bit 字、298 kbit 的整块图，TD 用了 89 块
//   （可用只有 64）。改成 2 bit/像素 + 按内容拆窗后只要 ~14 块。
//   2 bit 正好是 4 级灰度，抗锯齿够用；1 bit 硬边的笔画会明显发脆。
//
//     W1 = logo 圆弧 + 心电波形        (240, 80) 160x160
//     W2 = 中文标题 + 英文副标题        (176,244) 288x88
//     W3 = 底部"加载中..."              (256,416) 128x40
//
// 取图节奏
//   这条路上有两级寄存器（本模块的 addr_q 一级 + ROM 自己的输出寄存器一级），
//   所以地址要盯住"后面第二个像素"所在的那一组（4 像素/字），
//   这样每个有效像素拿到的就是它自己的字，rgb 不用加延迟、画面不会平移。
//=============================================================================
module splash_boot (
    input  wire        clk,      // video_clk（25 MHz）
    input  wire        rst,      // rst_video，高有效
    input  wire        vs,       // 与像素流同拍的场同步；极性无关，跳变即认
    input  wire        de,       // 有效像素使能（每行恰 640 拍）
    input  wire        hide,     // 1 = 已经有图可上屏，关掉开机画面
    output wire [23:0] rgb,      // 开机画面像素（窗口外为纯黑）
    output wire        active    // 开机画面正在接管输出
);

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
assign active = !hide;

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
