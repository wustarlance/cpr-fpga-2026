`timescale 1ns/1ps
//=============================================================================
// pcm_frame_tick.v —— 音频帧节拍发生器（fs = MCLK / 256）
//-----------------------------------------------------------------------------
// 整条音频链只有这一个"时基"：
//
//   12.288 MHz / 256 = 48.000 kHz = 送 HDMI 核的音频帧率
//
// 每 256 个 MCLK 拉一拍 O_frame_stb，pcm_player 就在这一拍决定"本帧要不要
// 从 FIFO 取下一个样本"。所以这个节拍必须严格等间隔，抖动会直接变成
// 重采样的相位抖动（44.1k 素材尤其明显，平均 0.918 个样本/帧）。
//
// 为什么单独一个模块、不塞进 pcm_player：
//   节拍是"音频主时钟"，播放器只是它的消费者。分开写，以后播放器加淡入
//   淡出、音量、静音渐变都不会动到全局时基；TB 里也能单独量它。
//
// 为什么不带参数：
//   MCLK/fs 固定 256，这是 HDMI 音频 MCLK 的标准关系（= 2 × 128×fs，
//   给每个声道留 64 个 BCLK 的余量）。要换采样率只能换 PLL 的 MCLK，
//   而不是改这个除数——改除数会让 HDMI 核的 ACR 对不上。
//
// 历史：本模块是 pcm_i2s_tx.v 砍掉 I2S 之后的版本（2026-10-22）。
//   原来的 64 bit 移位寄存器、BCLK/LRCK 分频、双缓冲 S_cur/S_nxt、
//   I_mute 门控全部删除——那些只服务于"把并行样本串成 I2S 三线"，
//   而 HDMI 现在走 wav_audio_path 第 6 节的 PCM 直连，用不到串行化。
//   删掉后这块逻辑从约 110 个触发器降到 9 个（8 bit 计数器 + 1 bit 节拍）。
//=============================================================================
module pcm_frame_tick (
    input  wire        I_mclk,        // 12.288 MHz（必须 = 256 × fs）
    input  wire        I_rst,         // 高有效，与音频域同一复位
    output reg         O_frame_stb    // 每 256 个 MCLK 一个单拍
);

localparam [7:0] DIV_LAST = 8'd255;   // 0..255 共 256 拍

reg [7:0] S_cnt;

always @(posedge I_mclk or posedge I_rst) begin
    if (I_rst) begin
        S_cnt       <= 8'd0;
        O_frame_stb <= 1'b0;
    end
    else begin
        O_frame_stb <= 1'b0;          // 默认 0，只在回绕那一拍拉高
        if (S_cnt == DIV_LAST) begin
            S_cnt       <= 8'd0;
            O_frame_stb <= 1'b1;
        end
        else begin
            S_cnt <= S_cnt + 8'd1;
        end
    end
end

endmodule
