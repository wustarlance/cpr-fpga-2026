`timescale 1ns/1ps
// 按显示页和模式选择 WAV 首扇区，并在选曲变化时重启读取。
// I_audio_sel：0..3 对应四页教程，4 对应自动展播背景曲，5..7 回退到第1段。
// 选曲码经两级同步和稳定过滤后生效；O_changed 拉宽供 abort/start 使用。
// 多位码跨域时可能出现短暂中间值，源端应保持选曲码稳定。
// 五段首LBA统一在下列参数定义；tools/burn_wav.py也从这里读取布局。
// 各段须留足音频长度。训练心跳由heartbeat_synth合成，不使用扇区表。
module wav_track_select #(
    parameter [31:0] PICTURE_1      = 32'd12000,   // 第 1 页对应 WAV 的首扇区
    parameter [31:0] PICTURE_2      = 32'd123000,  // 第 2 页
    parameter [31:0] PICTURE_3      = 32'd250000,  // 第 3 页
    parameter [31:0] PICTURE_4      = 32'd370000,  // 第 4 页
    parameter [31:0] FREE_SONG      = 32'd500000,  // 第 5 段：自动轮播模式的背景曲
    parameter integer STABLE_CYCLES = 8,          // 稳定过滤时长，单位I_clk周期
    parameter integer PULSE_CYCLES  = 4           // O_changed 脉宽参数
)(
    input  wire        I_clk,          // sd_card_clk（100 MHz）
    input  wire        I_rst,          // 高有效
    input  wire [2:0]  I_audio_sel,    // 选曲码 0..4；可跨时钟域
    output wire [31:0] O_sector,       // 选中的 WAV 首扇区（给 I_start_sector）
    output reg         O_changed       // 换页确认：多拍高电平，rising edge 只一次
);

/* ---------------------------------------------------------------------- */
/* 1. 2 级同步 + 稳定过滤                                                   */
/* ---------------------------------------------------------------------- */
// 保留整型比较值，避免 STABLE_CYCLES=8 被3位常量截断成0。
// 计数器为4位，当前参数范围为1..15。
localparam integer STABLE_TOP = STABLE_CYCLES;   // 只支持 1..15

reg [2:0] S_sel_meta;      // 第 1 级：异步输入落点（可能亚稳态）
reg [2:0] S_sel_sync;      // 第 2 级：稳定值
reg [2:0] S_sel_cand;      // 正在计时的候选值
reg [3:0] S_sel_cnt;       // 候选值已连续保持多少拍
reg [2:0] S_sel_lock;      // 已生效的选曲码（查表用这个）
reg       S_chg_evt;

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        S_sel_meta <= 3'd0;
        S_sel_sync <= 3'd0;
        S_sel_cand <= 3'd0;
        S_sel_cnt  <= 4'd0;
        S_sel_lock <= 3'd0;
        S_chg_evt  <= 1'b0;
    end
    else begin
        S_sel_meta <= I_audio_sel;
        S_sel_sync <= S_sel_meta;
        S_chg_evt  <= 1'b0;

        if (S_sel_sync != S_sel_cand) begin
            // 候选码变化后重新计时。
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
/* 2. 5 选 1（参数查表，综合成 5 个 32 bit 常量 + 一级 mux）                */
/* ---------------------------------------------------------------------- */
assign O_sector = (S_sel_lock == 3'd0) ? PICTURE_1 :
                  (S_sel_lock == 3'd1) ? PICTURE_2 :
                  (S_sel_lock == 3'd2) ? PICTURE_3 :
                  (S_sel_lock == 3'd3) ? PICTURE_4 :
                  (S_sel_lock == 3'd4) ? FREE_SONG :
                                         PICTURE_1;   // 5..7：未定义，退回第 1 段

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
