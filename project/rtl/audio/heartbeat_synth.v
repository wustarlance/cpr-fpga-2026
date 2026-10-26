`timescale 1ns/1ps
//=============================================================================
// heartbeat_synth.v —— 训练模式的心跳音合成（片内产生 PCM，不读卡）
//-----------------------------------------------------------------------------
// 训练模式要的"咚—哒"心跳不是一段录音，而是每次由参数直接算出来的：
//
//   第 1 声（"咚"）：150 Hz 正弦，25 ms，包络指数衰减，幅度 100%
//   第 2 声（"哒"）：190 Hz 正弦，35 ms，包络指数衰减，幅度 65%
//   （2026-10-26 按实听反馈整体升高约一个八度：原来的 75/95 Hz 在 HDMI
//     输出端偏"闷"，展台环境噪起来几乎听不出敲击感；只改频率，时长、间隔、
//     幅度比例、拍速全部不动，所以包络与拍长相关的断言仍然成立。）
//   两声间隔 70 ms（第 2 声从第 1 声起点算起 70 ms 处开始）
//   整拍周期 110 BPM → 545 ms，剩下的 440 ms 是静音间隔
//
// 为什么不用 SD 卡里的 WAV：
//   * 心跳要**一直循环**、而且在训练模式里独占音频口，读卡只会白占 SPI 总线；
//   * 两声的时长/频率/衰减全是参数，改风格不用重新烧卡、不用重新导素材；
//   * 不依赖 FAT/扇区布局，卡没插也能响（这点在展台现场很值钱）。
// 所以本模块是训练模式唯一的心跳音源：不读卡、不占扇区表。
// 注意扇区表里的第 5 段 FREE_SONG（500000，2026-10-26 新增）跟这里无关：
// 它是**自动轮播模式**的背景曲，训练模式下音频口被本模块独占（2:1 选择器），
// 所以两者不可能同时出声，也就不需要混音。
//
// 采样节拍：**不要自己分频**。训练模式的心跳必须和 WAV 通道同一个帧节拍
// （MCLK/256 ≈ 48 kHz，由 pcm_frame_tick 产生），否则两路各跑各的，
// 切换音源那一帧会多/少一个样本，听感是"咔"的一下爆音。
// 所以本模块只吃 I_frame_stb，一帧出一个样本。
//
// 输出：24 bit 左对齐（和 wav_reader 把 16/24 bit 统一左对齐的做法一致），
//       单声道 → 左右同值。幅度参数是 16 bit Q15，32767 = 0 dBFS(16 bit)。
//
// 开关与退出（2026-10-26 改）：
//   * I_enable 一拉高就从拍首"咚"开始，不等相位、不等包络，第一帧就是音头；
//   * I_enable 拉低时**不再立刻归零**。如果这一刻正响着（S_active=1），模块
//     会把包络按 env -= env>>2 快速压到 0（约 0.7 ms），并保持 O_busy=1；等到
//     包络真的到 0 才让 O_busy 落下，下游 §5.5 的选择器看到 O_busy 落下才切回
//     WAV。这样"退出训练"不会正好把一声"咚"从满幅中途截断（那是满量程阶跃，
//     必爆音），收尾完再切，切点上心跳侧已经是 0。
//   * 为什么不做 1~2 ms 的正式淡入淡出：那要一个 24 bit 增益乘法器（+1~2 DSP）
//     或 8~16 级移位斜坡（+100 LUT 量级）。当前选择器是硬切（2026-10-25 第五次
//     改删掉了混音与交叉淡化），退出瞬间的阶跃主要来自"WAV 那一侧此刻的幅度"，
//     靠心跳自己收尾并不能消除它；要彻底干净得把增益斜坡加到选择器输出上，
//     见 docs/heartbeat-synth-implementation.md §12。这一版只消除"满幅截断"
//     这一种最响的情况，代价是 0 个 DSP、约 10 个 LUT。
//   * 训练模式重新进入时若正好在收尾，会接着把这一声放完（不会从半声跳回拍首）。
//
// 音头与音尾（决定"峰值是不是真的等于标注的幅度"）：
//   * 相位每次从 0 起 → sin(0)=0，音头天然无爆音，不用另做 attack 斜坡；
//   * 先**满幅保持**到正弦的第一个波峰（= 1/(4f)，150 Hz 约 1.7 ms），之后才
//     开始 env -= env>>SHIFT 指数衰减。
//     这一条不能省：若从第 0 个样本就开始衰减，等到正弦爬到自己波峰时包络
//     已经掉到 50~80%，"幅度 100%"就和实际听到的峰值对不上，而且 150 Hz 与
//     190 Hz 两段的跌落比例不同（频率越高波峰来得越早、掉得越少），
//     65% 的比例会被吃掉。保持到波峰之后，峰值严格等于 AMP_FIRST/AMP_SECOND。
//   * SHIFT 取到"段落结束时衰减到 2% 以下"，段落结束时残值已经很小，硬切也听
//     不出咔哒（25/35 ms 段落配 SHIFT=8 在 150/190 Hz 下分别是 1.25% / 0.18%，
//     即 −38 dB / −55 dB）。注意 255/256 每帧，τ=256 帧≈5.33 ms，所以是
//     "每 256 帧衰减到 1/e"而不是"减半"，算残值别用 2^-n 的式子。
//
// 参数边界：PERIOD 用 16 bit 计数器存，BPM 低到 40 时是 72040 > 65535，
// 会溢出。本项目固定 110 BPM，若要更慢请把 S_idx 加宽。
//=============================================================================
module heartbeat_synth #(
    parameter integer MCLK_HZ        = 12_288_000, // 与 wav_audio_path 同一路 MCLK
    parameter integer BPM            = 110,        // 整拍频率
    parameter integer FREQ_FIRST     = 150,        // 第 1 声频率 Hz（2026-10-26：75→150）
    parameter integer FREQ_SECOND    = 190,        // 第 2 声频率 Hz（2026-10-26：95→190）
    parameter integer DUR_FIRST_MS   = 25,         // 第 1 声时长 ms
    parameter integer DUR_SECOND_MS  = 35,         // 第 2 声时长 ms
    parameter integer GAP_MS         = 70,         // 第 2 声起点（相对第 1 声）
    parameter integer AMP_FIRST      = 32767,      // 第 1 声幅度 Q15（100%）
    parameter integer AMP_SECOND     = 21300,      // 第 2 声幅度 Q15（≈65%）
    parameter integer DECAY_SHIFT_1  = 8,          // 第 1 声衰减：τ = 2^SHIFT 个样本
    parameter integer DECAY_SHIFT_2  = 8           // 第 2 声衰减
)(
    input  wire            I_clk,        // MCLK（12.295082 MHz）
    input  wire            I_rst,        // 高有效
    input  wire            I_frame_stb,  // 48 kHz 帧节拍（单拍）
    input  wire            I_enable,     // 1 = 训练模式，出声；0 = 静音并复位到拍首
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
// **乘法的位宽必须写死成 48 bit，不能用 `f * (1 << 24)`**（2026-10-26 踩过）：
// `1 << 24` 是 32 bit 有符号常数，`f * 2^24` 也就在 32 bit 里算。上限是
// 2^31−1，换成频率就是 127.99 Hz —— 75/95 Hz 时代一直没炸，把频率提到
// 150/190 Hz 就溢出了：150×2^24 = 2.52e9 变成负数，除完 FS 得到 −37028，
// 相位累加器等于每帧**倒着**走 37028，表指针从 63 往下数，听感是频率跑偏
// 且音高随包络往下滑。写 `f * 48'd16_777_216` 后乘法在 48 bit 里做，
// 频率上限变成 2^31/2^24 ≈ 128 kHz，怎么调都不会再溢出。
// 结果仍在 24 bit 内（任一频率 ≤ FS 时 inc ≤ 2^24），赋值时截低位是安全的。
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
            // ---- 退出收尾（2026-10-26 新增）----
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
wire signed [15:0] W_env_s = S_env;                  // ≤32767，按有符号看也安全
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
