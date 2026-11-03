`timescale 1ns/1ps
// PCM播放控制及最近邻重采样，输出帧节拍由pcm_frame_tick提供。
// I_play=0时保留进度且不读FIFO，输出静音；I_stop清进度，由上层重启reader。
// 输入样本采用{R[23:0],L[23:0]}，已在reader中按位深左对齐。
// 重采样累加输入采样率，达到FS_OUT时消耗下一个样本。
// FIFO读流水：帧边界决策，下一拍发读，再下一拍锁存，随后给出PCM valid。
// O_pcm_valid在暂停和静音时仍保持帧节拍，供HDMI ACR使用。
module pcm_player #(
    parameter integer MCLK_HZ  = 12_288_000,  // 音频 MCLK（帧率 = MCLK/256）
    parameter integer FIFO_addr_bits  = 10,
    parameter integer PREFILL  = 16           // 攒够这么多帧才开始出声
)(
    input  wire        I_clk,
    input  wire        I_rst,

    /* ---- 控制 / 配置 ---- */
    input  wire        I_play,
    input  wire        I_stop,          // 单拍脉冲
    input  wire [31:0] I_sample_rate,   // WAV 的 fs（准静态）
    input  wire [31:0] I_frame_total,   // 文件总帧数（0 = 未知，不判结束）

    /* ---- 采样节拍（来自 pcm_frame_tick） ---- */
    input  wire        I_frame_stb,

    /* ---- FIFO 读侧 ---- */
    output wire               O_fifo_rd,
    input  wire [47:0]        I_fifo_data,   // {R[23:0], L[23:0]}
    input  wire               I_fifo_valid,  // O_fifo_rd 之后一拍
    input  wire               I_fifo_empty,
    input  wire [FIFO_addr_bits:0]   I_fifo_level,

    /* ---- PCM 输出（送 HDMI 直连跨域 / 可选 I2S 发送器） ---- */
    output reg                O_pcm_valid,
    output reg  [23:0]        O_pcm_left,
    output reg  [23:0]        O_pcm_right,

    /* ---- 状态 / 诊断 ---- */
    output reg  [31:0]        O_play_pos,
    output reg                O_end,
    output reg                O_underrun,
    output reg  [31:0]        O_underrun_cnt,
    output wire [FIFO_addr_bits:0]   O_buf_level,
    output wire               O_empty
);

localparam integer FS_OUT = (MCLK_HZ + 128) / 256;   // 帧率 = MCLK/256（四舍五入）

//--------------------------------------------------------------------------
// 1. 最近邻重采样：输入 fs → 帧率 FS_OUT
//--------------------------------------------------------------------------
reg  [19:0] S_acc;
wire [19:0] W_acc_sum = S_acc + I_sample_rate[18:0];   // 支持的 fs <= 192k（19 bit 够）
wire        W_acc_over = (W_acc_sum >= FS_OUT);

// FIFO达到PREFILL后开始取数；清空后重新预充，启动等待不计为欠载。
reg S_primed;
always @(posedge I_clk or posedge I_rst) begin
    if (I_rst)                        S_primed <= 1'b0;
    else if (I_fifo_level >= PREFILL) S_primed <= 1'b1;
    else if (I_fifo_level == 0)       S_primed <= 1'b0;   // 停止/清空后重新预充
end

wire W_playing = I_play && S_primed;

//--------------------------------------------------------------------------
// 2. 帧边界决策：这一帧要不要取新样本
//--------------------------------------------------------------------------
reg S_pop;      // 已决策：下一拍拉 FIFO 读
reg S_have;     // 手里已有一对有效样本
reg [23:0] S_l, S_r;

wire W_need_new = !S_have || W_acc_over;

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        S_pop  <= 1'b0;
        S_acc  <= 20'd0;
    end
    else if (I_stop) begin
        S_pop  <= 1'b0;
        S_acc  <= 20'd0;
    end
    else if (I_frame_stb) begin
        if (W_playing && W_need_new) begin
            S_pop <= 1'b1;
            // 第一个样本不推进相位；之后每次取数扣掉一个 FS_OUT
            S_acc <= S_have ? (W_acc_sum - FS_OUT) : 20'd0;
        end
        else begin
            S_pop <= 1'b0;
            if (W_playing) S_acc <= W_acc_sum;
        end
    end
    else begin
        S_pop <= 1'b0;
    end
end

assign O_fifo_rd = S_pop && !I_fifo_empty;

//--------------------------------------------------------------------------
// 3. FIFO 寄存输出回来 → 锁存；顺便累计进度 / 统计断流
//--------------------------------------------------------------------------
always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        O_play_pos     <= 32'd0;
        O_underrun     <= 1'b0;
        O_underrun_cnt <= 32'd0;
        O_end          <= 1'b0;
        S_l            <= 24'd0;
        S_r            <= 24'd0;
        S_have         <= 1'b0;
    end
    else if (I_stop) begin
        O_play_pos     <= 32'd0;
        O_underrun     <= 1'b0;
        O_underrun_cnt <= 32'd0;
        O_end          <= 1'b0;
        S_l            <= 24'd0;
        S_r            <= 24'd0;
        S_have         <= 1'b0;
    end
    else begin
        if (I_fifo_valid) begin
            S_l        <= I_fifo_data[23:0];
            S_r        <= I_fifo_data[47:24];
            S_have     <= 1'b1;
            O_play_pos <= O_play_pos + 32'd1;
        end

        // 该取数但 FIFO 空：这一帧只能发静音，并且把手里这对旧样本丢掉，
        // 否则文件播完后会一直重复最后一个采样值（直流，听着是"嗡"）
        if (S_pop && I_fifo_empty) begin
            O_underrun     <= 1'b1;
            O_underrun_cnt <= O_underrun_cnt + 32'd1;
            S_have         <= 1'b0;
        end

        if ((I_frame_total != 32'd0) && (O_play_pos >= I_frame_total) &&
            I_fifo_empty && I_play)
            O_end <= 1'b1;
        else if (I_play && !I_fifo_empty)
            O_end <= 1'b0;
    end
end

//--------------------------------------------------------------------------
// 4. 输出：帧边界后第 3 拍打出 valid（FIFO 数据已在本拍之前锁好）
//--------------------------------------------------------------------------
reg [2:0] S_stb_d;
always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) S_stb_d <= 3'b000;
    else       S_stb_d <= {S_stb_d[1:0], I_frame_stb};
end

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        O_pcm_valid <= 1'b0;
        O_pcm_left  <= 24'd0;
        O_pcm_right <= 24'd0;
    end
    else if (S_stb_d[2]) begin
        // 暂停或还没拿到样本时发 0：帧节拍照常，只是听不见
        O_pcm_valid <= 1'b1;
        O_pcm_left  <= (W_playing && S_have) ? S_l : 24'd0;
        O_pcm_right <= (W_playing && S_have) ? S_r : 24'd0;
    end
    else begin
        O_pcm_valid <= 1'b0;
    end
end

assign O_buf_level = I_fifo_level;
assign O_empty     = I_fifo_empty;

endmodule
