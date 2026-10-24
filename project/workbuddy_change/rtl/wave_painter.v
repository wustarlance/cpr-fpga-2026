`timescale 1ns/1ps
//=============================================================================
// wave_painter.v —— 24 bit PCM 波形绘制器（双 bank RAM + 200×200 点阵窗口）
//-----------------------------------------------------------------------------
// 这一级对应视频路径里"SDRAM 帧缓存 → 送显示"的那一级，但它不是整屏帧缓存，
// 只在屏幕的一块矩形窗口里画东西：
//
//   I_smp_valid / I_smp_data[23:0]（48 kHz，来自 wav_audio_path 的 O_audio_*）
//        │
//        ▼
//   采集 FSM ──► 写 bank(~S_rd_bank)：COL_W 个样本攒满 → 置 S_pend
//        │
//        ▼
//   显示 bank(S_rd_bank) ──► 每个窗口像素读 1 个数 → 算行 → 与 y 比较
//        │
//        ▼
//   O_pix_hit / O_pix_rgb（比 I_pix_x/y 晚 2 拍）
//
// 一、为什么要双 bank
//   采样以 48 kHz 连续进来，显示却按 60 帧/秒整屏扫描。若只有一个存储体，
//   写指针会追上正在扫描的列 → 同一帧里上半截是新数据、下半截是旧数据
//   （撕裂，和视频帧缓存 tearing 是同一件事）。双 bank 后：扫描永远只读一个
//   bank，另一个 bank 在后面攒；攒满后在"本帧窗口左上角那个像素"处原子切换，
//   此时这一帧还没开始画窗口，接缝天然看不见。
//
// 二、为什么"攒满就停"（不去覆盖正在显示的 bank）
//   COL_W=200 个样本 @48 kHz 只要 4.17 ms，而一帧 16.7 ms。若让写侧自由跑，
//   一帧之内会把另一个 bank 反复覆盖 4 次，切过去时里面只剩最后 200 个样本的
//   残片。所以写满即停（S_cap=0），等换 bank（S_pend 被消费）再开始下一轮。
//   代价是"每帧只显示 4.17 ms 的**连续**片段"——不是抽点，片段内相邻样本
//   一个不少，横向时间比例是真实的。
//
// 三、行映射（24 bit → 200 行，一个常数乘法器搞定）
//   amp8 = sample[23:16]                  // 顶 8 bit（含符号位），相当于 >>16
//   row  = 100 ± (|amp8| * 25 >> 5)       // 25/32 = 0.781
//   +满刻度 127 → 第 1 行，-满刻度 -128 → 第 199 行，0 → 第 100 行（中线）
//   为什么取 25/32 而不是 1:1 —— 若 1:1，±100 行以外全被削成平顶线；
//   0.781 让 ±满刻度正好落在窗口内 1 像素处，全动态范围都在框里。
//
// 四、点怎么连成线（本模块最省资源的一招）
//   每个窗口像素只想读 **一个** 地址（= 列号），这样算不出"上一列的行"。
//   但扫描是 x 递增的，上一列的行就是"上一次读出来的行"——用一个
//   S_row_prev 寄存器记住它即可：**不需要第二个读口，也不需要写侧预算跨度**。
//   每个像素点亮 [min(prev,cur), max(prev,cur)] 这一整段，点自然连成线
//   （相邻样本相差几十行时尤其明显；列 0 没有上一列，单独画一个点）。
//
// 五、流水线与对齐（集成时必看）
//   t    ：I_pix_x/y 进来 → 算列号、发 RAM 读地址
//   t+1  ：RAM 出数（BRAM 1 拍），坐标同步打一拍
//   t+2  ：出 O_pix_hit / O_pix_rgb
//   所以 O_pix_hit 恒比 I_pix_x 晚 **2 个像素时钟**，同时给出 O_pix_de_d
//   （= I_pix_de 的两拍延迟）。混叠时按 O_pix_de_d 对齐，不要自己数拍：
//       assign pix_rgb = wave_hit ? wave_rgb : rgb_bg_d2;
//       assign pix_de  = wave_de  ? 1'b1 : pix_de_bg_d2;
//
// 六、触发（TRIG_EN）
//   上升零交叉（负 → 非负）开始采集，波形就"钉"在同一个相位上，不再左右
//   乱跑。静音时永远等不到触发，所以有 W_force：连续 TRIG_FREE_FRAMES 帧
//   没触发就自由采集一次，避免画面卡死（静音时画出一条中线）。
//
// 七、资源
//   2 × (256 × 24 bit) 推成 2 块 9 Kb BRAM（每个都是 1 写 1 读）；
//   组合逻辑 ~60-100 LUT（一个 8×5 常数乘 + 若干比较器）；寄存器 < 60。
//   比整屏帧缓存（640×480×24 = 7.4 Mbit）小两个数量级。
//
// 八、诊断口
//   O_wr_ptr / O_rd_bank / O_capturing / O_bank_ready / O_smp_cnt / O_frame_cnt
//   是给仿真和 ILA 看的。**上板时不要把 32 位的几个直接引 pad**——
//   wav_audio_timing_top 里踩过这个坑（491 个 pad > EG4S20 的 188 上限，
//   布局报 PHY-9016），请 XOR 归约成一位或者只接 ILA。
//=============================================================================
module wave_painter #(
    parameter integer COL_W    = 200,        // 窗口宽（列）= 每个 bank 存的样本数
    parameter integer ROW_H    = 200,        // 窗口高（行）
    parameter integer DEPTH    = 256,        // 每个 bank 的 RAM 深度（= 2^ADDR_BITS）
    parameter integer ADDR_BITS= 8,          // = log2(DEPTH)
    parameter integer X0       = 20,         // 窗口左上角（像素坐标）
    parameter integer Y0       = 240,
    parameter integer TRIG_EN  = 1,          // 1 = 上升零交叉触发
    parameter integer TRIG_FREE_FRAMES = 4,  // 连续这么多帧没触发 → 自由采集
    parameter [23:0]  COL_POINT = 24'h30E040,// 波形点（绿）
    parameter [23:0]  COL_AXIS  = 24'h303840,// 零线 / 中线（暗灰）
    parameter [23:0]  COL_FRAME = 24'hC8C8C8 // 边框（浅灰）
)(
    /* ---- 像素时钟域（= wav_audio_path 的 I_video_clk，25.175 MHz） ---- */
    input  wire        I_clk,
    input  wire        I_rst,

    /* ---- 采样流（同 I_clk 域；接 O_audio_valid / O_audio_left_data） ---- */
    input  wire        I_smp_valid,     // 48 kHz 单拍
    input  wire [23:0] I_smp_data,      // 24 bit 有符号，左对齐

    /* ---- 像素扫描（同 I_clk 域） ---- */
    input  wire [11:0] I_pix_x,
    input  wire [11:0] I_pix_y,
    input  wire        I_pix_de,

    /* ---- 绘制结果（比 I_pix_x/y 晚 2 拍） ---- */
    output reg         O_pix_hit,       // 1 = 本像素归波形窗口着色
    output reg  [23:0] O_pix_rgb,       // 窗口内颜色（RGB888，用 RGB565 请截断）
    output reg         O_pix_de_d,      // = I_pix_de 延 2 拍（对齐用）

    /* ---- 诊断（只接 ILA / XOR 归约，不要直接引 pad） ---- */
    output wire [ADDR_BITS-1:0] O_wr_ptr,
    output wire        O_rd_bank,       // 正在显示的 bank
    output wire        O_capturing,     // 正在采集
    output wire        O_bank_ready,    // 攒满、等下一帧起点
    output wire [31:0] O_smp_cnt,
    output wire [31:0] O_frame_cnt
);

// 中线行号（窗口内坐标）。用定宽 localparam，避免 integer 参与位宽推导。
localparam [9:0]   ROW_MID_C = ROW_H / 2;

//--------------------------------------------------------------------------
// 0. 存储体：两个 bank，各 24 bit × DEPTH
//    写成"条件写 + 条件读"的样子，TD 会推成两个 1 写 1 读的 BRAM。
//--------------------------------------------------------------------------
reg [23:0] S_smp_b0 [0:DEPTH-1];
reg [23:0] S_smp_b1 [0:DEPTH-1];

//--------------------------------------------------------------------------
// 0b. 窗口几何（采集侧和显示侧都要用，先算出来）
//--------------------------------------------------------------------------
wire        W_in_win = I_pix_de
                    && (I_pix_x >= X0) && (I_pix_x < (X0 + COL_W))
                    && (I_pix_y >= Y0) && (I_pix_y < (Y0 + ROW_H));
wire [ADDR_BITS-1:0] W_col = I_pix_x - X0;    // 只在 W_in_win 时有意义

//--------------------------------------------------------------------------
// 1. 采集侧状态
//--------------------------------------------------------------------------
reg  [ADDR_BITS-1:0] S_wr_ptr;
reg        S_sign_prev;   // 上一个样本的符号位（判零交叉）
reg        S_cap;         // 正在采集本 bank
reg        S_pend;        // 本 bank 已攒满，等本帧窗口起点换过去
reg        S_rd_bank;     // 0 = 显示 b0 / 写 b1；1 = 显示 b1 / 写 b0
reg        S_bank_valid;  // 至少换过一次（之前显示的 bank 里是空的）
reg  [7:0] S_no_trig;
reg [31:0] S_smp_cnt, S_frame_cnt;

// 换 bank 的时机：窗口第一行第一列那个像素，每帧恰好一次。
//
// ⚠️ 这里踩过两个坑，写下来免得再犯：
//    1) 最初用"I_pix_de 的上升沿"当帧起点 —— 但 DE 是**行**有效，每行开头都
//       拉高一次 → 每个行周期（320 拍）就换一次 bank，比采样还快，采集永远
//       攒不满；同时 S_no_trig 疯涨触发"自由采集"，于是每帧显示的都是一段
//       随机相位的样本（现象：波形看着像，但和输入对不上、每帧都不重样）。
//    2) 改成"W_in_win 的上升沿"还是每行一次 —— 窗口有 ROW_H 行，每行开头
//       那个像素都在窗口内，同样会上升。
//    最终就是下面这一行：定位到"窗口左上角那一个像素"。换 bank 点落在
//    这一帧还没开始画的位置，天然看不见接缝。
wire W_win_start = I_pix_de && (I_pix_x == X0) && (I_pix_y == Y0);

// 触发 / 自由采集
wire W_trig  = S_sign_prev & ~I_smp_data[23];        // 负 → 非负
wire W_force = (S_no_trig >= TRIG_FREE_FRAMES);
wire W_start = (TRIG_EN != 0) ? (W_trig | W_force) : 1'b1;

// 本拍要不要写 bank：两种情况——本 bank 的第一个样本、本 bank 的后续样本
//
// ⚠️ 起采条件里必须有 ~S_pend：S_pend=1 表示"另一个 bank 已攒满、正等着
//    本帧起点换过去"，此刻写侧的目标 bank 还是它，一旦起采就会把待显示的
//    数据从第 0 列开始覆盖掉（表现为屏幕左边一截是新数据、右边是旧数据）。
wire W_cap_first = I_smp_valid & ~S_cap & ~S_pend & W_start;
wire W_cap_more  = I_smp_valid &  S_cap;
wire W_wr_en     = W_cap_first | W_cap_more;
wire [ADDR_BITS-1:0] W_wr_addr = W_cap_first ? {ADDR_BITS{1'b0}} : S_wr_ptr;

// 采集 FSM + 换 bank（同一个 always，避免多驱动）
always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        S_wr_ptr     <= {ADDR_BITS{1'b0}};
        S_sign_prev  <= 1'b0;
        S_cap        <= 1'b0;
        S_pend       <= 1'b0;
        S_rd_bank    <= 1'b0;
        S_bank_valid <= 1'b0;
        S_no_trig    <= 8'd0;
        S_smp_cnt    <= 32'd0;
        S_frame_cnt  <= 32'd0;
    end
    else if (W_win_start) begin
        // 有攒满的 bank → 本帧窗口起点原子切换
        if (S_pend) begin
            S_rd_bank    <= ~S_rd_bank;
            S_pend       <= 1'b0;
            S_bank_valid <= 1'b1;
            S_frame_cnt  <= S_frame_cnt + 32'd1;
        end
        if (S_cap | S_pend) S_no_trig <= 8'd0;
        else if (S_no_trig != 8'hFF) S_no_trig <= S_no_trig + 8'd1;
    end
    else if (I_smp_valid) begin
        S_smp_cnt   <= S_smp_cnt + 32'd1;
        S_sign_prev <= I_smp_data[23];

        if (W_cap_first) begin
            // 第 0 列就是这个样本，指针指向 1
            S_cap    <= 1'b1;
            S_wr_ptr <= {{(ADDR_BITS-1){1'b0}}, 1'b1};
        end
        else if (W_cap_more) begin
            if (S_wr_ptr == (COL_W - 1)) begin
                S_cap    <= 1'b0;      // 攒满即停，等换 bank
                S_pend   <= 1'b1;
                S_wr_ptr <= {ADDR_BITS{1'b0}};
            end
            else begin
                S_wr_ptr <= S_wr_ptr + {{(ADDR_BITS-1){1'b0}}, 1'b1};
            end
        end
    end
end

// 写侧（独立的 always，无复位，便于推断 BRAM）
always @(posedge I_clk) begin
    if (W_wr_en) begin
        if (S_rd_bank) S_smp_b0[W_wr_addr] <= I_smp_data;   // 显示 b1 → 写 b0
        else           S_smp_b1[W_wr_addr] <= I_smp_data;   // 显示 b0 → 写 b1
    end
end

//--------------------------------------------------------------------------
// 2. 显示侧：列号 → RAM 读 → 行 → 与 y 比较
//    （W_in_win / W_col 在第 0b 节已经定义，这里直接用）
//--------------------------------------------------------------------------

// 第 1 拍：RAM 出数 + 坐标打拍
reg [23:0] S_rd_data;
reg [11:0] S_x1, S_y1;
reg        S_in1;
reg [ADDR_BITS-1:0] S_col1;

always @(posedge I_clk) begin
    if (S_rd_bank) S_rd_data <= S_smp_b1[W_col];
    else           S_rd_data <= S_smp_b0[W_col];
end

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        S_x1   <= 12'd0;
        S_y1   <= 12'd0;
        S_in1  <= 1'b0;
        S_col1 <= {ADDR_BITS{1'b0}};
    end
    else begin
        S_x1   <= I_pix_x;
        S_y1   <= I_pix_y;
        S_in1  <= W_in_win;
        S_col1 <= W_col;
    end
end

// 24 bit → 行（全无符号算，避免有符号移位在综合器上的边界行为）
wire [7:0]  W_amp  = S_rd_data[23:16];
wire        W_neg  = W_amp[7];
wire [7:0]  W_abs  = W_neg ? (~W_amp + 8'd1) : W_amp;    // 0..128
wire [12:0] W_prod = {5'd0, W_abs} * 5'd25;              // ≤ 3200
wire [8:0]  W_off  = W_prod[12:5];                       // /32 → 0..100
wire [9:0]  W_row_s= W_neg ? (ROW_MID_C + W_off)         // 负样本 → 中线以下
                           : (ROW_MID_C - W_off);
wire [7:0]  W_row  = (W_row_s > (ROW_H - 1)) ? (ROW_H - 1) : W_row_s[7:0];

// 上一列的行：扫描 x 递增，所以它就是"上一次算出来的行"
reg  [7:0] S_row_prev;
always @(posedge I_clk or posedge I_rst) begin
    if (I_rst)       S_row_prev <= 8'd0;
    else if (S_in1)  S_row_prev <= W_row;
end

wire [7:0] W_row_p = (S_col1 == {ADDR_BITS{1'b0}}) ? W_row : S_row_prev;
wire [7:0] W_lo    = (W_row < W_row_p) ? W_row : W_row_p;
wire [7:0] W_hi    = (W_row < W_row_p) ? W_row_p : W_row;

// 换 bank 瞬间的屏蔽：读口里还挂着换 bank 之前发出的那 1~2 个数（旧 bank 的），
// 若不屏蔽，窗口左上角会有 1~2 个像素按旧 bank 的数去比较——真机上只是"边框上
// 一个点画错"，仿真里会一路传出 X（旧 bank 复位后还没写过）。屏蔽 3 拍，
// 位置正好落在窗口边框上（本来就画成边框色），肉眼无影响。
reg [2:0] S_blank;
always @(posedge I_clk or posedge I_rst) begin
    if (I_rst)                        S_blank <= 3'b111;
    else if (W_win_start & S_pend)    S_blank <= 3'b111;
    else                              S_blank <= {S_blank[1:0], 1'b0};
end
wire W_pt_ok = ~(|S_blank);

// 第 2 拍：出结果
wire W_is_pt   = S_in1 && S_bank_valid && W_pt_ok &&
                 (S_y1 >= (Y0 + W_lo)) && (S_y1 <= (Y0 + W_hi));
wire W_is_axis = S_in1 && (S_y1 == (Y0 + ROW_MID_C));
wire W_is_bord = S_in1 && ((S_x1 == X0) || (S_x1 == (X0 + COL_W - 1)) ||
                          (S_y1 == Y0) || (S_y1 == (Y0 + ROW_H - 1)));

// O_pix_de_d 的语义是"DE 延两拍"（不是"窗口内"），调用方拿它对背景像素。
// 别拿 O_pix_hit 的 0 当 DE 用：窗口外的像素 hit 也是 0，会把背景也一起关掉。
reg S_de1, S_de2;
always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        S_de1 <= 1'b0;
        S_de2 <= 1'b0;
    end
    else begin
        S_de1 <= I_pix_de;
        S_de2 <= S_de1;
    end
end

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        O_pix_hit  <= 1'b0;
        O_pix_rgb  <= 24'd0;
        O_pix_de_d <= 1'b0;
    end
    else begin
        O_pix_hit  <= W_is_pt | W_is_bord | W_is_axis;
        O_pix_rgb  <= W_is_pt   ? COL_POINT :
                      W_is_bord ? COL_FRAME : COL_AXIS;
        O_pix_de_d <= S_de2;
    end
end

//--------------------------------------------------------------------------
// 3. 诊断
//--------------------------------------------------------------------------
assign O_wr_ptr     = S_wr_ptr;
assign O_rd_bank    = S_rd_bank;
assign O_capturing  = S_cap;
assign O_bank_ready = S_pend;
assign O_smp_cnt    = S_smp_cnt;
assign O_frame_cnt  = S_frame_cnt;

endmodule
