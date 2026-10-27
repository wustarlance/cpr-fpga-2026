`timescale 1ns/1ps
//=============================================================================
// heart_mix_stage.v —— 训练心跳与页音频的"合流"：选择 + 混音 + 两段斜坡
//-----------------------------------------------------------------------------
// 输入两路"整源"（都是 24 bit 左对齐、同一路 48 kHz 帧节拍）：
//   A = 该页 WAV（pcm_player 输出，已过 SW4 暂停闸）
//   B = 心跳（heartbeat_synth 合成，单声道复制成左右）
// 两个开关：
//   I_sel_heart  0 = 输出音乐（教学/展播）；1 = 输出心跳（训练模式）
//   I_sel_mix    1 = 心跳上再叠一层该页音乐（"背景乐 + 心跳"）
// 输出：O_l / O_r
//
// 结构（两段 2 ms 线性斜坡，串联）：
//   W_g   = fade(0 → A, I_sel_mix)        音乐以斜坡"混进"心跳这一路
//   B_mix = sat(B + W_g)                  饱和加法，不削波、不翻相
//   O     = fade(A → B_mix, I_sel_heart)  主交叉淡化
//
// 为什么是"两段斜坡"而不是"一个 2:1 mux + 一段斜坡"：
//   * 训练进出：主淡化把 A 平滑换成 B_mix，两个方向都连续，两端也精确
//     （α=0 逐位等于 A，α 满逐位等于 B_mix）；
//   * 混音开关（硬件 F13、`depth_sw_n[3]`）可以在**训练中间**拨动。若直接
//     用 mux 把 B 从"心跳"换成"心跳+音乐"，B 是阶跃，而主淡化此时 α 已经
//     是满的（还没开始新的淡化），阶跃会原样出现在输出上 —— 就是一声"咔"。
//     所以音乐要**先以斜坡进入 B**，让 B 自己保持连续。
//   * 于是这里根本不需要 mux：混音关时 W_g 的斜坡退回 0，B_mix 自然等于心跳。
//
// 两段斜坡都复用 audio_crossfade：它本身是 out = A + (B-A)·α，把 A 接 0 就
// 退化成"输入 × α"的淡入闸，不用新写斜坡逻辑，也不用额外查找表。
//
// 定标：输入/输出都是 24 bit 左对齐（满量程 ±8388607），和 wav_reader /
// pcm_player / heartbeat_synth 一致，中间加法多留 1 bit 判溢出。
//=============================================================================
module heart_mix_stage #(
    parameter integer MCLK_HZ = 12_288_000,   // 与 pcm_player / heartbeat_synth 同源
    parameter integer FADE_MS = 2             // 每一段斜坡的时长
)(
    input  wire                     I_clk,        // MCLK
    input  wire                     I_rst,        // 高有效
    input  wire                     I_frame_stb,  // 48 kHz 帧节拍（单拍）
    input  wire                     I_sel_heart,  // 0 = 音乐；1 = 心跳
    input  wire                     I_sel_mix,    // 1 = 心跳 + 音乐
    input  wire signed [23:0]       I_a_l,        // 页音频
    input  wire signed [23:0]       I_a_r,
    input  wire signed [23:0]       I_b_l,        // 心跳
    input  wire signed [23:0]       I_b_r,
    output wire signed [23:0]       O_l,
    output wire signed [23:0]       O_r
);

/* ---------------------------------------------------------------------- */
/* 1. 音乐以 2 ms 斜坡进入"混音路"：A 接到 0，输出就是 A×α                   */
/* ---------------------------------------------------------------------- */
wire signed [23:0] W_gate_l, W_gate_r;

audio_crossfade #(
    .MCLK_HZ (MCLK_HZ),
    .FADE_MS (FADE_MS)
) u_mixgate (
    .I_clk       (I_clk),
    .I_rst       (I_rst),
    .I_frame_stb (I_frame_stb),
    .I_sel       (I_sel_mix),
    .I_a_l       (24'sd0),
    .I_a_r       (24'sd0),
    .I_b_l       (I_a_l),
    .I_b_r       (I_a_r),
    .O_l         (W_gate_l),
    .O_r         (W_gate_r),
    .O_mixing    ()
);

/* ---------------------------------------------------------------------- */
/* 2. 饱和相加：25 bit 判断，超界夹到边界，不翻相（翻相就是一声"啪"）        */
/* ---------------------------------------------------------------------- */
wire signed [24:0] W_sum_l = $signed({I_b_l[23], I_b_l}) + $signed(W_gate_l);
wire signed [24:0] W_sum_r = $signed({I_b_r[23], I_b_r}) + $signed(W_gate_r);

wire signed [23:0] W_bmix_l = (W_sum_l >  25'sd8388607) ? 24'sh7FFFFF :
                              (W_sum_l < -25'sd8388608) ? 24'sh800000 : W_sum_l[23:0];
wire signed [23:0] W_bmix_r = (W_sum_r >  25'sd8388607) ? 24'sh7FFFFF :
                              (W_sum_r < -25'sd8388608) ? 24'sh800000 : W_sum_r[23:0];

/* ---------------------------------------------------------------------- */
/* 3. 主交叉淡化：A（音乐）←→ B_mix（心跳，或心跳+音乐）                     */
/* ---------------------------------------------------------------------- */
audio_crossfade #(
    .MCLK_HZ (MCLK_HZ),
    .FADE_MS (FADE_MS)
) u_main (
    .I_clk       (I_clk),
    .I_rst       (I_rst),
    .I_frame_stb (I_frame_stb),
    .I_sel       (I_sel_heart),
    .I_a_l       (I_a_l),
    .I_a_r       (I_a_r),
    .I_b_l       (W_bmix_l),
    .I_b_r       (W_bmix_r),
    .O_l         (O_l),
    .O_r         (O_r),
    .O_mixing    ()
);

endmodule
