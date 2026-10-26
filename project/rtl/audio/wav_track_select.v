`timescale 1ns/1ps
//=============================================================================
// wav_track_select.v —— 按"当前上屏页号"选 WAV 起始扇区
//-----------------------------------------------------------------------------
// 为什么单独一级：
//   选谁 = 4 选 1 的扇区查表；什么时候重新读 = 换页的那一拍。前者是数据，
//   后者要送给 wav_audio_path 的 abort→start 状态机。混在 wav_audio_sd_top
//   里会让那一层既管时钟域又管状态机，拆出来还能单独仿真（tb_wav_track_select）。
//
// 三条处理，缺一不可：
//   1) 2 级同步：页号来自 SDRAM 侧（ext_mem_clk），到 sd_card_clk 必须同步；
//   2) 稳定过滤：页号是 2 bit 二进制码，01→10 时两位同时翻转，逐位同步可能
//      冒出一个"中间值"并只活一拍。这里要求连续 STABLE_CYCLES 拍
//      不变才认，中间值挺不过 1 拍，被直接滤掉；
//   3) O_changed 脉宽 4 拍：交给 wav_audio_path 的 I_stop 走"abort→start"，
//      重新锁存新的起始扇区并清两侧 FIFO —— "换页即换曲"就是靠这一拍。
//
// 扇区号是参数，不是散落在代码里的常量。**本文件的四个默认值是全工程唯一
// 一处定义**：wav_audio_sd_top 例化本模块时不写参数覆盖，顶层更不写，所以
// 改扇区只改下面这四行，不存在"改了顶层却被别处默认值盖回去"的情况。
//
// 当前四段布局（每段起点 = 该页 WAV 的首扇区，段与段之间必须留够自身长度）：
//   PICTURE_1 = 12000   紧接缩放测试 BMP 镜像（占 LBA 0..11853）之后
//   PICTURE_2 = 123000
//   PICTURE_3 = 250000
//   PICTURE_4 = 370000
// 相邻间距依次是 111000 / 127000 / 120000 扇区（≈54 / 62 / 59 MiB，
// 48 kHz/16 bit 单声道下约合 590 / 675 / 640 秒）。
// tools/burn_wav.py 也从这几行解析默认 LBA，两边不会不一致；写卡前它会把
// 四段位置和本次要写的长度一起打出来，越界（盖住下一段）直接中止。
//
// 注意：本模块只负责"选扇区"。训练模式**不走这里**——训练模式的心跳由
// rtl/audio/heartbeat_synth.v 片内合成，不读卡（2026-10-25 决定删除卡上
// 第 5 段 HEART_BEAT=500000 的方案，只保留片内合成一条路）。
//=============================================================================
module wav_track_select #(
    parameter [31:0] PICTURE_1      = 32'd12000,   // 第 1 页对应 WAV 的首扇区
    parameter [31:0] PICTURE_2      = 32'd123000,  // 第 2 页
    parameter [31:0] PICTURE_3      = 32'd250000,  // 第 3 页
    parameter [31:0] PICTURE_4      = 32'd370000,  // 第 4 页
    parameter integer STABLE_CYCLES = 8,          // 连续不变多少拍才认（I_clk 周期）
    parameter integer PULSE_CYCLES  = 4           // O_changed 宽度，够跨一道同步
)(
    input  wire        I_clk,          // sd_card_clk（100 MHz）
    input  wire        I_rst,          // 高有效
    input  wire [1:0]  I_audio_sel,    // 页号 0..3；可跨时钟域
    output wire [31:0] O_sector,       // 选中的 WAV 首扇区（给 I_start_sector）
    output reg         O_changed       // 换页确认：多拍高电平，rising edge 只一次
);

/* ---------------------------------------------------------------------- */
/* 1. 2 级同步 + 稳定过滤                                                   */
/* ---------------------------------------------------------------------- */
// 注意：这里必须是整型常量。原先写的是 [2:0]，STABLE_CYCLES=8 被
// 截成 3'b000 —— 于是"连续稳定 8 拍才认"实际退化成"下一拍就认"，页号在
// 01→10 / 11→00 这种两位同时翻转时冒出的中间值会被当成一次真换页，
// 白白多触发一次 abort（多读一个扇区、还多清一次 FIFO）。
localparam integer STABLE_TOP = STABLE_CYCLES;   // 只支持 1..15

reg [1:0] S_sel_meta;      // 第 1 级：异步输入落点（可能亚稳态）
reg [1:0] S_sel_sync;      // 第 2 级：稳定值
reg [1:0] S_sel_cand;      // 正在计时的候选值
reg [3:0] S_sel_cnt;       // 候选值已连续保持多少拍
reg [1:0] S_sel_lock;      // 已生效的页号（查表用这个）
reg       S_chg_evt;

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        S_sel_meta <= 2'd0;
        S_sel_sync <= 2'd0;
        S_sel_cand <= 2'd0;
        S_sel_cnt  <= 4'd0;
        S_sel_lock <= 2'd0;
        S_chg_evt  <= 1'b0;
    end
    else begin
        S_sel_meta <= I_audio_sel;
        S_sel_sync <= S_sel_meta;
        S_chg_evt  <= 1'b0;

        if (S_sel_sync != S_sel_cand) begin
            // 变了就重新计时（中间值只会出现在这里，一拍后又被下一拍覆盖）
            S_sel_cand <= S_sel_sync;
            S_sel_cnt  <= 4'd0;
        end
        else if (S_sel_cnt != STABLE_TOP) begin
            S_sel_cnt <= S_sel_cnt + 4'd1;
        end
        else if (S_sel_lock != S_sel_cand) begin
            S_sel_lock <= S_sel_cand;   // 确认换页
            S_chg_evt  <= 1'b1;
        end
    end
end

/* ---------------------------------------------------------------------- */
/* 2. 4 选 1（参数查表，综合成 4 个 32 bit 常量 + 一级 mux）                */
/* ---------------------------------------------------------------------- */
assign O_sector = (S_sel_lock == 2'd0) ? PICTURE_1 :
                  (S_sel_lock == 2'd1) ? PICTURE_2 :
                  (S_sel_lock == 2'd2) ? PICTURE_3 :
                                          PICTURE_4;

/* ---------------------------------------------------------------------- */
/* 3. 变化沿拉宽成 PULSE_CYCLES 拍（1 拍脉宽跨时钟域容易被漏采）            */
/* ---------------------------------------------------------------------- */
localparam [2:0] PULSE_TOP = PULSE_CYCLES;     // 1..7
reg [2:0] S_chg_cnt;

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst)                        S_chg_cnt <= 3'd0;
    else if (S_chg_evt)               S_chg_cnt <= PULSE_TOP;
    else if (S_chg_cnt != 3'd0)       S_chg_cnt <= S_chg_cnt - 3'd1;
end

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) O_changed <= 1'b0;
    else       O_changed <= (S_chg_cnt != 3'd0) | S_chg_evt;
end

endmodule
