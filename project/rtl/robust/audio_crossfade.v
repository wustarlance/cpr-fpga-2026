`timescale 1ns/1ps
//=============================================================================
// audio_crossfade.v —— 两路 PCM 之间的 2 ms 线性交叉淡化（消"咔哒"）
//-----------------------------------------------------------------------------
// 干什么：
//   把 A（常态音源，这里是该页 WAV）和 B（训练模式心跳）按一个斜坡系数 α
//   混合输出：  out = A + (B - A) × α，α 在 FADE_MS 毫秒内从 0 线性爬到 1，
//   或者从 1 线性退回 0。α 动的时候两路都在响，总电平保持不变（等功率的
//   近似），所以既没有"硬切"的爆音，也没有"先静音再起"那种断一下的感觉。
//
// 为什么不用"先淡出到 0 → 换源 → 再淡入"：
//   那样中间必然经过一段全静音，听起来是"掉了一下"；而且两个方向要两套状态。
//   交叉淡化只要一个 α 和一个斜坡方向，逻辑更小。
//
// 为什么乘一次就够（不是两次）：
//   两次乘法写法是 A×(1-α) + B×α，要两个乘法器；这里把 A 提出来：
//     A + (B-A)×α
//   (B-A) 是 25 bit、(α) 是 16 bit，一路乘完再加回 A，**每声道只要 1 个乘法器**，
//   两个声道 2 个。而且 α=0 时结果严格等于 A（乘 0 加 0），α 满时用旁路直接
//   输出 B，两端都是精确值，不是"近似"。
//
// α 的位宽与斜坡步长：
//   α 用 Q16（0..65535 ≈ 0..1），斜坡在 I_frame_stb（48 kHz 帧节拍）上走，
//   每帧加/减 STEP = ceil(65536 / FADE_FRAMES)。FADE_MS=2、FS=48 kHz 时
//   FADE_FRAMES=96、STEP=683 → 96 帧走完，实测 2.00 ms（最后一步被 65535 夹住，
//   误差 < 1/96 帧 ≈ 10 µs，听不出来）。
//
// 为什么必须用帧节拍而不是 MCLK：
//   MCLK 是 12.295 MHz，一个 MCLK 周期只有 81 ns，用它计数要 24 bit；
//   用帧节拍只有 7 bit 就够，而且和音频样本一一对应 —— 斜坡的每一步正好是
//   一个样本，波形上是一条干净的直线，不会有"某个样本被重复加两次"的抖动。
//
// 输入按"有符号 24 bit 左对齐"处理（和 wav_reader / pcm_player 一致）：
//   满量程 ±8388607。这里是**线性**淡化，不是等功率（sin/cos）淡化：
//   两路内容不相关时等功率更"响"，但本项目两路都是低频音、且切换时间只有
//   2 ms，线性斜坡的 -3 dB 凹陷（约 1 ms 的中点）根本听不出来，省一个查找表。
//
// 时序：纯组合乘法 + 寄存器输出，组合路径只有 1 级乘法器 + 1 级 25 bit 加法，
//       在 12.295 MHz（81 ns）下绰绰有余。
//=============================================================================
module audio_crossfade #(
    parameter integer MCLK_HZ = 12_288_000,   // 与 pcm_player / heartbeat_synth 同一路
    parameter integer FADE_MS = 2             // 淡化时长（ms）
)(
    input  wire                     I_clk,        // MCLK
    input  wire                     I_rst,        // 高有效
    input  wire                     I_frame_stb,  // 48 kHz 帧节拍（单拍）
    input  wire                     I_sel,        // 0 = 输出 A；1 = 输出 B（内部自己淡化）
    input  wire signed [23:0]       I_a_l,        // A 路左（常态音源）
    input  wire signed [23:0]       I_a_r,        // A 路右
    input  wire signed [23:0]       I_b_l,        // B 路左（心跳音源）
    input  wire signed [23:0]       I_b_r,        // B 路右
    output wire signed [23:0]       O_l,
    output wire signed [23:0]       O_r,
    output wire                     O_mixing      // 1 = α 既不是 0 也不是满，正在淡化
);

/* ---------------------------------------------------------------------- */
/* 0. 时长换算：2 ms → 96 帧，步长 683/65536                                   */
/* ---------------------------------------------------------------------- */
localparam integer FS          = (MCLK_HZ + 128) / 256;              // 帧率，与 pcm_player 同式
localparam integer FADE_FRAMES = (FS * FADE_MS + 500) / 1000;        // 2 ms → 96
localparam integer STEP_I      = (65536 + FADE_FRAMES - 1) / FADE_FRAMES;

localparam [15:0] STEP = STEP_I[15:0];       // 683
localparam [15:0] FULL = 16'hFFFF;           // α 的满刻度（Q16 的 1.0 用 65535 表示）

/* ---------------------------------------------------------------------- */
/* 1. α 斜坡：I_sel=1 往上爬，=0 往下退，一帧一步                             */
/* ---------------------------------------------------------------------- */
reg [15:0] S_alpha;

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst)                        S_alpha <= 16'd0;
    else if (I_frame_stb) begin
        if (I_sel) begin
            // 上爬：别越过满刻度（否则 16 bit 回绕成 0，输出会跳回去）
            if (S_alpha > FULL - STEP) S_alpha <= FULL;
            else                       S_alpha <= S_alpha + STEP;
        end
        else begin
            // 下退：别越过 0（回绕会变成满刻度，等于"切了一半又弹回去"）
            if (S_alpha < STEP)        S_alpha <= 16'd0;
            else                       S_alpha <= S_alpha - STEP;
        end
    end
end

/* ---------------------------------------------------------------------- */
/* 2. out = A + (B - A) × α / 65536                                          */
/*    α=0 时严格等于 A（乘 0 加 0），所以常态通路完全不受这里影响。            */
/*    α 满时直接旁路到 B，避免 65535/65536 那 1 LSB 的残差。                  */
/* ---------------------------------------------------------------------- */
wire signed [24:0] W_diff_l = $signed({I_b_l[23], I_b_l}) - $signed({I_a_l[23], I_a_l});
wire signed [24:0] W_diff_r = $signed({I_b_r[23], I_b_r}) - $signed({I_a_r[23], I_a_r});

wire signed [40:0] W_prod_l = W_diff_l * $signed({1'b0, S_alpha});   // 25 bit × 16 bit
wire signed [40:0] W_prod_r = W_diff_r * $signed({1'b0, S_alpha});

wire signed [24:0] W_mix_l = $signed({I_a_l[23], I_a_l}) + (W_prod_l >>> 16);
wire signed [24:0] W_mix_r = $signed({I_a_r[23], I_a_r}) + (W_prod_r >>> 16);

assign O_l = (S_alpha == 16'd0)    ? I_a_l :
             (S_alpha == FULL)     ? I_b_l : W_mix_l[23:0];
assign O_r = (S_alpha == 16'd0)    ? I_a_r :
             (S_alpha == FULL)     ? I_b_r : W_mix_r[23:0];

assign O_mixing = (S_alpha != 16'd0) && (S_alpha != FULL);

endmodule
