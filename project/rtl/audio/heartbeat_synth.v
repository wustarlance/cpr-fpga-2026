`timescale 1ns/1ps
// 训练心跳合成：两段衰减正弦PCM，不读TF卡，左右声道同值。
// 默认150 Hz/25 ms与190 Hz/35 ms，第二声在70 ms开始，整拍110 BPM。
// 与WAV共用I_frame_stb（MCLK/256），每个节拍产生一个24位左对齐样本。
// 幅度参数为Q15；先保持到首个波峰，再按env -= env>>SHIFT衰减。
// BOOST_DECAY提高衰减段能量，保留原峰值及两声强弱比例。
// 禁用时若仍在发声，以env -= env>>2收尾；O_busy期间下游保留心跳音源。
// 重新启用若遇收尾中的声部，会先完成该声部。音源切换未作交叉淡化，
// 心跳归零后仍可能与WAV当前幅度产生阶跃，见heartbeat-synth-implementation.md。
// S_idx只有16位；降低BPM前需检查PERIOD是否超出65535。
module heartbeat_synth #(
    parameter integer MCLK_HZ        = 12_288_000, // 与 wav_audio_path 同一路 MCLK
    parameter integer BPM            = 110,        // 整拍频率
    parameter integer FREQ_FIRST     = 150,        // 第1声频率，Hz
    parameter integer FREQ_SECOND    = 190,        // 第2声频率，Hz
    parameter integer DUR_FIRST_MS   = 25,         // 第 1 声时长 ms
    parameter integer DUR_SECOND_MS  = 35,         // 第 2 声时长 ms
    parameter integer GAP_MS         = 70,         // 第 2 声起点（相对第 1 声）
    parameter integer AMP_FIRST      = 32767,      // 第 1 声幅度 Q15（100%）
    parameter integer AMP_SECOND     = 21300,      // 第 2 声幅度 Q15（≈65%）
    parameter integer DECAY_SHIFT_1  = 8,          // 第 1 声衰减：τ = 2^SHIFT 个样本
    parameter integer DECAY_SHIFT_2  = 8,          // 第 2 声衰减
    // Lift the decaying envelope while retaining each hit's original peak.
    // 0 retains the original waveform; 1 increases energy without PCM clipping.
    parameter integer BOOST_DECAY    = 1
)(
    input  wire            I_clk,        // MCLK（12.295082 MHz）
    input  wire            I_rst,        // 高有效
    input  wire            I_frame_stb,  // 48 kHz 帧节拍（单拍）
    input  wire            I_enable,     // 1=合成心跳；0=收尾后静音并回到拍首
    output wire            O_busy,       // 1 = 正在发声（含退出时的收尾），此时不能切源
    output reg  [23:0]     O_left,
    output reg  [23:0]     O_right
);

/* ---------------------------------------------------------------------- */
/* 0. 时长换算：全部折成"样本数"常量，运行时不做乘除                        */
/* ---------------------------------------------------------------------- */
localparam integer FS = (MCLK_HZ + 128) / 256;                    // 帧率，与 pcm_player 同式
localparam integer PERIOD_I = (FS * 60 + BPM / 2) / BPM;          // 一拍样本数（110BPM→26182）
localparam integer DUR1_I   = (FS * DUR_FIRST_MS  + 500) / 1000;  // 25 ms
localparam integer DUR2_I   = (FS * DUR_SECOND_MS + 500) / 1000;  // 35 ms
localparam integer GAP_I    = (FS * GAP_MS        + 500) / 1000;  // 70 ms

localparam [15:0] PERIOD = PERIOD_I[15:0];
localparam [15:0] DUR1   = DUR1_I[15:0];
localparam [15:0] DUR2   = DUR2_I[15:0];
localparam [15:0] GAP    = GAP_I[15:0];
// 相位增量：inc = f × 2^24 / FS，相位取高 6 bit 查 64 点正弦表。
//
// 使用48位乘法计算f*2^24，避免32位有符号中间值在150/190 Hz时溢出。
// 相位增量截为24位；调整频率时还需满足采样率和相位宽度约束。
localparam [23:0] INC1 = (FREQ_FIRST  * 48'd16_777_216) / FS;
localparam [23:0] INC2 = (FREQ_SECOND * 48'd16_777_216) / FS;
localparam [15:0] AMP1 = AMP_FIRST[15:0];
localparam [15:0] AMP2 = AMP_SECOND[15:0];
// 满幅保持到正弦第一个波峰：t = 1/(4f) 秒 → (2^22 / INC) 个样本
// （150 Hz→80 帧≈1.67 ms，190 Hz→63 帧≈1.31 ms）
localparam [15:0] HOLD1 = (48'd4_194_304 / INC1);
localparam [15:0] HOLD2 = (48'd4_194_304 / INC2);

/* ---------------------------------------------------------------------- */
/* 1. 状态寄存器（先声明，正弦表要用 S_phase）                              */
/* ---------------------------------------------------------------------- */
reg [23:0] S_phase;    // 相位累加器
reg [15:0] S_env;      // 包络（Q15，无符号，0..32767）
reg [15:0] S_peak;     // 当前声部原峰值；保留两声100%/65%的强弱比例
reg [15:0] S_dur;      // 当前这一声还剩多少个样本
reg [15:0] S_hold;     // 衰减开始前还要满幅保持多少个样本
reg [23:0] S_inc;      // 当前这一声的相位增量
reg [3:0]  S_shift;    // 当前这一声的衰减移位
reg        S_active;   // 当前在发声
reg [15:0] S_idx;      // 拍内样本序号 0..PERIOD-1

/* ---------------------------------------------------------------------- */
/* 2. 64 点正弦表（正负全表，Q15 有符号）                                   */
/*    综合成分布式 ROM（64×16 bit），不占块 RAM                             */
/* ---------------------------------------------------------------------- */
reg signed [15:0] S_sin;
always @(*) begin
    case (S_phase[23:18])
        6'd0 : S_sin =  16'sd     0;   6'd1 : S_sin =  16'sd  3212;
        6'd2 : S_sin =  16'sd  6393;   6'd3 : S_sin =  16'sd  9512;
        6'd4 : S_sin =  16'sd 12539;   6'd5 : S_sin =  16'sd 15446;
        6'd6 : S_sin =  16'sd 18204;   6'd7 : S_sin =  16'sd 20787;
        6'd8 : S_sin =  16'sd 23170;   6'd9 : S_sin =  16'sd 25329;
        6'd10: S_sin =  16'sd 27245;   6'd11: S_sin =  16'sd 28898;
        6'd12: S_sin =  16'sd 30273;   6'd13: S_sin =  16'sd 31356;
        6'd14: S_sin =  16'sd 32137;   6'd15: S_sin =  16'sd 32609;
        6'd16: S_sin =  16'sd 32767;   6'd17: S_sin =  16'sd 32609;
        6'd18: S_sin =  16'sd 32137;   6'd19: S_sin =  16'sd 31356;
        6'd20: S_sin =  16'sd 30273;   6'd21: S_sin =  16'sd 28898;
        6'd22: S_sin =  16'sd 27245;   6'd23: S_sin =  16'sd 25329;
        6'd24: S_sin =  16'sd 23170;   6'd25: S_sin =  16'sd 20787;
        6'd26: S_sin =  16'sd 18204;   6'd27: S_sin =  16'sd 15446;
        6'd28: S_sin =  16'sd 12539;   6'd29: S_sin =  16'sd  9512;
        6'd30: S_sin =  16'sd  6393;   6'd31: S_sin =  16'sd  3212;
        6'd32: S_sin = -16'sd     0;   6'd33: S_sin = -16'sd  3212;
        6'd34: S_sin = -16'sd  6393;   6'd35: S_sin = -16'sd  9512;
        6'd36: S_sin = -16'sd 12539;   6'd37: S_sin = -16'sd 15446;
        6'd38: S_sin = -16'sd 18204;   6'd39: S_sin = -16'sd 20787;
        6'd40: S_sin = -16'sd 23170;   6'd41: S_sin = -16'sd 25329;
        6'd42: S_sin = -16'sd 27245;   6'd43: S_sin = -16'sd 28898;
        6'd44: S_sin = -16'sd 30273;   6'd45: S_sin = -16'sd 31356;
        6'd46: S_sin = -16'sd 32137;   6'd47: S_sin = -16'sd 32609;
        6'd48: S_sin = -16'sd 32767;   6'd49: S_sin = -16'sd 32609;
        6'd50: S_sin = -16'sd 32137;   6'd51: S_sin = -16'sd 31356;
        6'd52: S_sin = -16'sd 30273;   6'd53: S_sin = -16'sd 28898;
        6'd54: S_sin = -16'sd 27245;   6'd55: S_sin = -16'sd 25329;
        6'd56: S_sin = -16'sd 23170;   6'd57: S_sin = -16'sd 20787;
        6'd58: S_sin = -16'sd 18204;   6'd59: S_sin = -16'sd 15446;
        6'd60: S_sin = -16'sd 12539;   6'd61: S_sin = -16'sd  9512;
        6'd62: S_sin = -16'sd  6393;   6'd63: S_sin = -16'sd  3212;
        default: S_sin = 16'sd 0;
    endcase
end

/* ---------------------------------------------------------------------- */
/* 3. 拍内计时：第 1 声 → 间隔 → 第 2 声 → 静音 → 下一拍                    */
/* ---------------------------------------------------------------------- */
always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        S_phase  <= 24'd0;
        S_env    <= 16'd0;
        S_peak   <= AMP1;
        S_dur    <= 16'd0;
        S_hold   <= 16'd0;
        S_inc    <= INC1;
        S_shift  <= DECAY_SHIFT_1[3:0];
        S_active <= 1'b0;
        S_idx    <= 16'd0;
    end
    else if (!I_enable) begin
        if (!S_active) begin
            // 关掉且已经不在发声：回到拍首。下次使能的第一帧就是"咚"，
            // 不会卡在半声上（这一支每拍都跑，保持 S_idx 一直被压在 0）。
            S_phase  <= 24'd0;
            S_env    <= 16'd0;
            S_dur    <= 16'd0;
            S_hold   <= 16'd0;
            S_active <= 1'b0;
            S_idx    <= 16'd0;
        end
        else if (I_frame_stb) begin
            // 禁用后的包络收尾
            // 正在响的时候把 I_enable 拉低，不要在这一帧直接归零：那等于把
            // 正弦从此刻的幅度（可能满幅 ±0x7F7F00）一刀切到 0，是会听见的爆音。
            // 这里继续出正弦，只把包络按 env -= env>>2 压下去（每帧剩 75%，
            // 32767 → <4 约 32 帧 = 0.67 ms），收尾期间 O_busy 保持 1，
            // 下游选择器就不切源。S_idx / S_dur 不推进：这一声就地消失。
            if ((S_env >> 2) == 16'd0) begin
                // 已经压到 <4 LSB（−78 dBFS），一刀切到 0 听不出来
                S_active <= 1'b0;
                S_env    <= 16'd0;
                S_phase  <= 24'd0;
                S_idx    <= 16'd0;      // 顺手回到拍首，哪怕下一拍立刻重新使能也是"咚"
            end
            else begin
                S_phase <= S_phase + S_inc;
                S_env   <= S_env - (S_env >> 2);
            end
        end
    end
    else if (I_frame_stb) begin
        // ---- 拍内序号推进（到 PERIOD 归零 = 110 BPM） ----
        if (S_idx >= PERIOD - 16'd1) S_idx <= 16'd0;
        else                         S_idx <= S_idx + 16'd1;

        if (S_idx == 16'd0) begin
            // ---- 第 1 声起点 ----
            S_env    <= AMP1;
            S_peak   <= AMP1;
            S_phase  <= 24'd0;
            S_inc    <= INC1;
            S_shift  <= DECAY_SHIFT_1[3:0];
            S_hold   <= HOLD1;
            S_dur    <= DUR1;
            S_active <= 1'b1;
        end
        else if (S_idx == GAP) begin
            // ---- 第 2 声起点（第 1 声早已收尾：25 ms < 70 ms） ----
            S_env    <= AMP2;
            S_peak   <= AMP2;
            S_phase  <= 24'd0;
            S_inc    <= INC2;
            S_shift  <= DECAY_SHIFT_2[3:0];
            S_hold   <= HOLD2;
            S_dur    <= DUR2;
            S_active <= 1'b1;
        end
        else if (S_active) begin
            // ---- 发声过程中：相位前进；先满幅保持到波峰，再指数衰减 ----
            S_phase <= S_phase + S_inc;
            if (S_hold != 16'd0) S_hold <= S_hold - 16'd1;
            else                 S_env  <= S_env - (S_env >> S_shift);
            if (S_dur <= 16'd1) S_active <= 1'b0;
            else                S_dur    <= S_dur - 16'd1;
        end
    end
end

/* ---------------------------------------------------------------------- */
/* 4. 乘包络 → 24 bit 左对齐输出                                           */
/*    一个 16×16 乘法器（综合成 1 个 DSP），一帧用一次                       */
/*    S_active 而不是 (I_enable && S_active)：退出收尾那 32 帧还要出声音，    */
/*    否则收尾就只是"提前 0.7 ms 归零"，等于没做。                            */
/* ---------------------------------------------------------------------- */
// A full-scale first hit has no amplitude headroom. Boost only its envelope's
// decaying region, clamping at the original per-hit peak BEFORE the sine
// multiplication. This keeps a sinusoid instead of clipping PCM wave crests.
wire [16:0] W_env_double = {S_env,1'b0};
wire [15:0] W_env_louder = (W_env_double>{1'b0,S_peak}) ?
                           S_peak : W_env_double[15:0];
wire signed [15:0] W_env_s = BOOST_DECAY ? W_env_louder : S_env;
wire signed [31:0] W_prod  = S_sin * W_env_s;        // Q15 × Q15 = Q30
wire signed [15:0] W_smp   = W_prod[30:15];          // 回到 Q15

// 给下游选择器：还在发声（含收尾）就不能切源
assign O_busy = S_active;

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        O_left  <= 24'd0;
        O_right <= 24'd0;
    end
    else if (S_active) begin
        O_left  <= {W_smp, 8'd0};               // 左对齐，与 wav_reader 一致
        O_right <= {W_smp, 8'd0};               // 单声道 → 左右同值
    end
    else begin
        O_left  <= 24'd0;
        O_right <= 24'd0;
    end
end

endmodule
