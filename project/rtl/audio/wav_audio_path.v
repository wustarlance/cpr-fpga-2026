`timescale 1ns/1ps
//=============================================================================
// wav_audio_path.v —— TF 卡 WAV → HDMI 音频（WAV 路径总装）
//-----------------------------------------------------------------------------
// 与视频路径逐级对应：
//
//   视频： bmp_read / bmp_read_scaled → SDRAM 帧缓存 → 视频 AXIS  → HDMI 视频口
//   音频： wav_reader                 → PCM FIFO     → PCM 播放控制器
//                                     → 直连 PCM + ACR → HDMI 音频口
//
// 音频数据通路（2026-10-22 起改为 PCM 直连，不再走 I2S 串行回环）：
//
//   pcm_frame_tick（MCLK 域）
//        │  O_frame_stb：每 256 个 MCLK 一拍（fs = 48 kHz）
//        ▼
//   pcm_player（MCLK 域）
//        │  {L,R} 24 bit + O_pcm_valid 单拍（fs ≈ 48 kHz，间隔 20.8 µs）
//        │
//        ├──► 5.5 节：二选一 —— I_heart_en=0 出 WAV；=1 出 heartbeat_synth
//        │            （训练模式"咚—哒"，硬切，无混音、无淡化；
//        │              退出训练时等心跳自己收尾 0.7 ms 再切回 WAV）
//        ▼
//        翻转握手跨域 ──► audio_valid + L/R（video_clk 域）
//        │                                      │
//        │                                      ▼
//        │                              audio_arc_calculate（N=6144）
//        │                                      │ acr_valid/cts/n
//        │                                      ▼
//        │                              HDMI 1.4b 发送核音频口
//
// 为什么不是 I2S（2026-10-22 已把整条串行路径删掉，历史留档）：
//   I2S_receiver 用 3 级同步后的 BCLK 上升沿采样，而 BCLK = MCLK/2、
//   一个 BCLK 周期只有 2 个 MCLK 周期，采样窗口正好卡在边界；直连是
//   48 bit 并行数据 + 单拍 valid，只要保证"数据先稳定、标志后翻转"，
//   就没有采样边界问题（见第 6 节注释）。
//   串行那一路（64 bit 移位寄存器 + BCLK/LRCK）已整段删除，只留下帧节拍；
//   以后要驱动外置 I2S DAC 时，单独写一个"并行进、三线出"的发送器即可，
//   不要再去动这里的时基和 HDMI 通路。
//
// 三个时钟域（和参考工程完全一致）：
//   I_sd_clk     100 MHz   SD 扇区读 + wav_reader + FIFO 写侧
//   I_mclk       12.288 MHz 帧节拍 + 播放控制器；fs = MCLK/256 = 48 kHz
//   I_video_clk  25.175 MHz ACR + HDMI 核（像素时钟）
//
// 文件从哪来：顶层用 I_start_sector 直接给（不扫卡、不解析 FAT32）。和
// bmp_read 的 load_sector 是同一个用法；失败就报错。
//=============================================================================
module wav_audio_path #(
    parameter integer MCLK_HZ             = 12_288_000,  // fs = MCLK/256
    parameter integer pcm_bits               = 24,          // 送 HDMI 核的样本位宽
    parameter integer FIFO_DEPTH          = 1024,
    parameter integer FIFO_addr_bits             = 10,
    parameter integer ACR_N               = 6144,        // N >> 7 = 6144 / 128 = 48;
    // 下面两个都是 **sd_clk 周期数**，不是 ns：
    //   100_000_000 周期 × 10 ns = 1 s（sd_clk = 100 MHz）
    parameter integer WAIT_TIMEOUT_CYCLES = 100_000_000, // 单扇区 1 s 无字节 → 超时
    // 出错后等多久再重解析。原来是 1 s：一旦解析失败，用户在那一秒里换页
    // 也听不到任何反应，看起来就是"卡死在上一首"。100 ms 足够让卡把上一次
    // 事务收干净，又不会让人觉得按了没反应。
    parameter integer RETRY_CYCLES        = 10_000_000  // 出错后等 100 ms 再重解析
)(
    /* ================= SD 扇区读接口（I_sd_clk 域，接 sd_card_top） ========= */
    input  wire        I_sd_clk,
    input  wire        I_sd_rst,          // 高有效
    input  wire        I_sd_init_done,
    input  wire        I_sd_sec_ready,
    input  wire [7:0]  I_sd_sec_data,
    input  wire        I_sd_sec_valid,
    input  wire        I_sd_sec_end,
    input  wire        I_sd_sec_error,
    output wire [31:0] O_sd_sec_addr,
    output wire        O_sd_sec_read,

    /* ================= 文件位置 ============================================ */
    input  wire [31:0] I_start_sector,    // WAV 文件首扇区

    /* ================= I2S 发送时钟域（MCLK = 12.288 MHz） ================= */
    input  wire        I_mclk,
    input  wire        I_mclk_rst,        

    /* ================= 像素时钟域（25.175 MHz，接 HDMI 核） ================ */
    input  wire        I_video_clk,
    input  wire        I_video_rst,       

    /* ================= 控制 ================================================ */
    input  wire        I_play,            // 1 = 播放；0 = 暂停（发静音，不消耗 FIFO）
    input  wire        I_stop,            // 单拍：回到文件开头
    input  wire        I_mute,            // 1 = 静音（帧节拍照常走，样本清 0）；内部两级同步
    input  wire        I_loop,            // 1 = 单文件循环

    /* ================= 训练模式心跳插播（2026-10-25 新增） ================= */
    // 训练模式的音频不是卡里的音乐，而是片内合成的"咚—哒"心跳（heartbeat_synth）。
    // 这一级就是一个 2:1 多路选择器：同一套帧节拍下二选一，
    //   0 → WAV（pcm_player），1 → 心跳。没有混音、没有淡化。
    // I_heart_en 从 video_clk 域来，内部两级同步成 W_heart_m 才当 sel 用；
    // 心跳正在发声时还会把 sel 按住（见 §5.5 的 W_sel）。
    input  wire        I_heart_en,        // 0 = 出该页 WAV；1 = 出心跳（训练模式）

    /* ================= 送 HDMI 1.4b 发送核 ================================= */
    output wire                    O_audio_valid,
    output wire [pcm_bits-1:0]        O_audio_left_data,
    output wire [pcm_bits-1:0]        O_audio_right_data,
    output wire                    O_acr_valid,
    output wire [19:0]             O_acr_cts,
    output wire [19:0]             O_acr_n,

    /* ================= 状态 / 诊断 ========================================= */
    output wire        O_wav_ready,
    output wire        O_wav_error,
    output wire [3:0]  O_wav_error_code,
    output wire [3:0]  O_wav_state,
    output wire [31:0] O_file_size,
    output wire [31:0] O_sample_rate,
    output wire [15:0] O_channels,
    output wire [15:0] O_bits,
    output wire [31:0] O_data_bytes,
    output wire [31:0] O_frame_total,
    output wire [31:0] O_play_pos,
    output wire        O_play_end,        // 文件播完（FIFO 空且播够帧数）
    output wire [FIFO_addr_bits:0] O_buf_level,
    output wire        O_underrun,
    output wire [31:0] O_underrun_cnt,
    output wire [31:0] O_sector_cnt,
    output wire [31:0] O_frame_cnt
);

/* ======================================================================== */
/* 0. 控制信号跨域：I_stop / I_loop                                          */
/*    人按按钮是毫秒级，两级同步就够；停止还要在两侧各拉 16 拍复位 FIFO。      */
/* ======================================================================== */
reg [1:0] S_stop_sd_sync;
reg [1:0] S_loop_sd_sync;
always @(posedge I_sd_clk or posedge I_sd_rst) begin
    if (I_sd_rst) begin
        S_stop_sd_sync <= 2'b00;
        S_loop_sd_sync <= 2'b00;
    end
    else begin
        S_stop_sd_sync <= {S_stop_sd_sync[0], I_stop};
        S_loop_sd_sync <= {S_loop_sd_sync[0], I_loop};
    end
end
wire W_loop_sd = S_loop_sd_sync[1];
wire W_stop_sd_edge = S_stop_sd_sync[1] & ~S_stop_sd_sync[0];  // 单拍

// 停止后 16 拍内保持"清空"状态（写侧）
reg [3:0] S_stop_sd_cnt;
always @(posedge I_sd_clk or posedge I_sd_rst) begin
    if (I_sd_rst)                    S_stop_sd_cnt <= 4'd0;
    else if (W_stop_sd_edge)         S_stop_sd_cnt <= 4'hF;
    else if (S_stop_sd_cnt != 4'd0)  S_stop_sd_cnt <= S_stop_sd_cnt - 4'd1;
end
wire W_stop_sd = (S_stop_sd_cnt != 4'd0);

// 停止事件用 toggle 过到 MCLK 域（保证每次按键都被看到，不依赖脉宽）
reg S_stop_tog;
always @(posedge I_sd_clk or posedge I_sd_rst) begin
    if (I_sd_rst)            S_stop_tog <= 1'b0;
    else if (W_stop_sd_edge) S_stop_tog <= ~S_stop_tog;
end

reg [2:0] S_tog_m;
always @(posedge I_mclk or posedge I_mclk_rst) begin
    if (I_mclk_rst) S_tog_m <= 3'b000;
    else            S_tog_m <= {S_tog_m[1:0], S_stop_tog};
end
wire W_stop_m_edge = S_tog_m[2] ^ S_tog_m[1];

reg [3:0] S_stop_m_cnt;
always @(posedge I_mclk or posedge I_mclk_rst) begin
    if (I_mclk_rst)                  S_stop_m_cnt <= 4'd0;
    else if (W_stop_m_edge)          S_stop_m_cnt <= 4'hF;
    else if (S_stop_m_cnt != 4'd0)   S_stop_m_cnt <= S_stop_m_cnt - 4'd1;
end
wire W_stop_m = (S_stop_m_cnt != 4'd0);

/* ======================================================================== */
/* 1. 顶层序列器（SD 时钟域）：等卡 → 启动 → 跑；出错/停止 → 重来           */
/* ======================================================================== */
localparam [2:0] Q_WAIT_INIT = 3'd0;
localparam [2:0] Q_START     = 3'd1;
localparam [2:0] Q_RUN       = 3'd2;
localparam [2:0] Q_ABORT     = 3'd3;
localparam [2:0] Q_RETRY     = 3'd4;

reg [2:0]  S_q;
reg        S_wav_start;
reg        S_wav_abort;
reg [3:0]  S_abort_cnt;
reg [31:0] S_retry_cnt;

//--------------------------------------------------------------------------
// 换曲时"等在跑的扇区真的收尾"（2026-10-25 修：换页换曲偶发卡死）
//
// 现象：连续换过几首后，再前进/后退到某一页，音乐卡在那一首上不再换，
//       之后换图也不换曲（reader 报 ERR_NOT_RIFF，再等 1 s 才重试）。
//
// 根因：vendor 的 sd_card_sec_read_write 一旦进 S_READ，**不看 sd_sec_read
//       是否撤销**，照样把 512 字节发完并给一个 sd_sec_read_end。而这里
//       abort 后固定 8 拍就发 start，新的 header 解析正好撞上旧扇区剩下的
//       字节和那个旧 end —— 解析直接在扇区中途"结束"，RIFF 校验失败。
//       换页时如果 reader 恰好不在收数（FIFO 满、在等空间），就没事，
//       所以这个故障是"有时候"才出现，正好符合上板看到的现象。
//
// 修法：abort 之后先让 reader 回 IDLE（旧请求随之撤销），然后等那个在跑的
//       事务把 end 交出来再发 start；没有在跑的事务就直接走。
//       end 迟迟不来（卡被拔、BMP 正在独占）时按 DRAIN_MAX 兜底放行。
//--------------------------------------------------------------------------
localparam [17:0] DRAIN_MAX = 18'd100_000;   // 1 ms @100 MHz（一个扇区 SPI 约 0.25 ms）

reg [17:0] S_drain_cnt;
reg        S_drain_need;
reg        S_drain_seen;   // abort 期间已经等到过 end

wire        W_wav_busy, W_wav_done, W_wav_err, W_wav_hdr;
wire [3:0]  W_wav_ecode, W_wav_state;
wire [31:0] W_wav_addr;
wire        W_wav_read;
wire [47:0] W_wav_pcm;        // {R[23:0], L[23:0]}
wire        W_wav_pcm_v;
wire [31:0] W_wav_sr, W_wav_fsz, W_wav_dbytes, W_wav_dsec, W_wav_ftotal;
wire [15:0] W_wav_ch, W_wav_bits;
wire [31:0] W_wav_scnt, W_wav_fcnt;
wire [11:0] W_fifo_space_w;

always @(posedge I_sd_clk or posedge I_sd_rst) begin
    if (I_sd_rst) begin
        S_q          <= Q_WAIT_INIT;
        S_wav_start  <= 1'b0;
        S_wav_abort  <= 1'b0;
        S_abort_cnt  <= 4'd0;
        S_retry_cnt  <= 32'd0;
        S_drain_cnt  <= 18'd0;
        S_drain_need <= 1'b0;
        S_drain_seen <= 1'b0;
    end
    else begin
        S_wav_start <= 1'b0;

        case (S_q)
        Q_WAIT_INIT: begin
            S_wav_abort <= 1'b0;
            if (I_sd_init_done) S_q <= Q_START;
        end

        Q_START: begin
            S_wav_abort <= 1'b0;
            S_wav_start <= 1'b1;
            S_q         <= Q_RUN;
        end

        Q_RUN: begin
            if (W_stop_sd_edge) begin
                // 先丢掉正在进行的扇区请求，再重新从文件头开始。
                // W_wav_read 记下"此刻是否真有一次扇区事务在外面"，
                // 决定 Q_ABORT 要不要等它收尾。
                S_wav_abort  <= 1'b1;
                S_abort_cnt  <= 4'd8;
                S_drain_need <= W_wav_read;
                S_drain_cnt  <= 18'd0;
                S_drain_seen <= 1'b0;
                S_q          <= Q_ABORT;
            end
            else if (W_wav_err) begin
                S_retry_cnt <= 32'd0;
                S_q         <= Q_RETRY;
            end
        end

        Q_ABORT: begin
            // 在 abort 的这 8 拍里旧事务可能就收尾了，先记下来，
            // 免得固定等到 8 拍之后去采样时已经错过那个单拍 end。
            if (I_sd_sec_end) S_drain_seen <= 1'b1;
            if (S_abort_cnt != 4'd0) begin
                S_abort_cnt <= S_abort_cnt - 4'd1;
            end
            else begin
                S_wav_abort <= 1'b0;
                // 旧扇区还在发字节：等它的 end 交出来再启动，否则新解析会被
                // 旧的 end 截断（ERR_NOT_RIFF）。没有在跑的事务就直接走。
                if (!S_drain_need || S_drain_seen || I_sd_sec_end ||
                    (S_drain_cnt >= DRAIN_MAX)) begin
                    S_drain_need <= 1'b0;
                    S_drain_seen <= 1'b0;
                    S_drain_cnt  <= 18'd0;
                    S_wav_start  <= 1'b1;
                    S_q          <= Q_RUN;
                end
                else begin
                    S_drain_cnt <= S_drain_cnt + 18'd1;
                end
            end
        end

        Q_RETRY: begin
            S_wav_abort <= 1'b0;
            // 重试等待期间换了页也要立刻响应，不能把这次换页吞掉
            if (W_stop_sd_edge) begin
                S_wav_abort  <= 1'b1;
                S_abort_cnt  <= 4'd8;
                S_drain_need <= W_wav_read;
                S_drain_cnt  <= 18'd0;
                S_drain_seen <= 1'b0;
                S_retry_cnt  <= 32'd0;
                S_q          <= Q_ABORT;
            end
            else if (!W_wav_busy) begin
                if (S_retry_cnt >= RETRY_CYCLES) begin
                    S_retry_cnt <= 32'd0;
                    S_q         <= Q_START;
                end
                else S_retry_cnt <= S_retry_cnt + 32'd1;
            end
        end

        default: S_q <= Q_WAIT_INIT;
        endcase
    end
end

/* ======================================================================== */
/* 2. WAV 读取器（SD 时钟域）                                                */
/* ======================================================================== */
wav_reader #(
    .WAIT_TIMEOUT_CYCLES (WAIT_TIMEOUT_CYCLES),
    .SEC_MIN_SPACE       (12'd512)
) u_wav_reader (
    .I_clk           (I_sd_clk),
    .I_rst           (I_sd_rst),
    .I_sd_init_done  (I_sd_init_done),
    .I_sd_sec_ready  (I_sd_sec_ready),
    .I_sd_sec_data   (I_sd_sec_data),
    .I_sd_sec_valid  (I_sd_sec_valid),
    .I_sd_sec_end    (I_sd_sec_end),
    .I_sd_sec_error  (I_sd_sec_error),
    .O_sd_sec_addr   (W_wav_addr),
    .O_sd_sec_read   (W_wav_read),
    .I_start         (S_wav_start),
    .I_start_sector  (I_start_sector),
    .I_abort         (S_wav_abort),
    .I_loop          (W_loop_sd),
    .O_pcm_data      (W_wav_pcm),
    .O_pcm_valid     (W_wav_pcm_v),
    .I_fifo_space    (W_fifo_space_w),
    .O_busy          (W_wav_busy),
    .O_done          (W_wav_done),
    .O_error         (W_wav_err),
    .O_error_code    (W_wav_ecode),
    .O_state_code    (W_wav_state),
    .O_hdr_ready     (W_wav_hdr),
    .O_file_size     (W_wav_fsz),
    .O_sample_rate   (W_wav_sr),
    .O_channels      (W_wav_ch),
    .O_bits          (W_wav_bits),
    .O_data_bytes    (W_wav_dbytes),
    .O_data_sector   (W_wav_dsec),
    .O_frame_total   (W_wav_ftotal),
    .O_sector_cnt    (W_wav_scnt),
    .O_frame_cnt     (W_wav_fcnt)
);

// 没有第二个 SD 使用者，直接连出去
assign O_sd_sec_read = W_wav_read;
assign O_sd_sec_addr = W_wav_addr;

/* ======================================================================== */
/* 3. PCM FIFO（写侧 SD 时钟，读侧 MCLK）                                    */
/* ======================================================================== */
wire             W_fifo_full;
wire [FIFO_addr_bits:0] W_fifo_wspace;
wire [47:0]      W_fifo_rdata;
wire             W_fifo_rvalid;
wire             W_fifo_empty;
wire [FIFO_addr_bits:0] W_fifo_level;
wire [FIFO_addr_bits:0] W_fifo_max;
wire             W_fifo_rd;

assign W_fifo_space_w = W_fifo_wspace;   // 11 bit -> 12 bit 零扩展

pcm_fifo #(
    .WIDTH (48),                       // 24 bit × 2 声道
    .DEPTH (FIFO_DEPTH),
    .ADDR_DEPTH    (FIFO_addr_bits)
) u_pcm_fifo (
    .I_wclk    (I_sd_clk),
    .I_wrst    (I_sd_rst | W_stop_sd),      // 停止时两侧一起清，指针同时归零
    .I_wr_en   (W_wav_pcm_v),
    .I_wr_data (W_wav_pcm),
    .O_wr_full (W_fifo_full),
    .O_wr_space(W_fifo_wspace),
    .I_rclk    (I_mclk),
    .I_rrst    (I_mclk_rst | W_stop_m),
    .I_rd_en   (W_fifo_rd),
    .O_rd_data (W_fifo_rdata),
    .O_rd_valid(W_fifo_rvalid),
    .O_rd_empty(W_fifo_empty),
    .O_rd_level(W_fifo_level),
    .O_rd_max  (W_fifo_max)
);

/* ======================================================================== */
/* 4. 配置跨域：数据稳定 + toggle 做"数据已更新"标志                          */
/* ======================================================================== */
reg        S_cfg_tog;
reg        S_cfg_seen;
always @(posedge I_sd_clk or posedge I_sd_rst) begin
    if (I_sd_rst) begin
        S_cfg_tog  <= 1'b0;
        S_cfg_seen <= 1'b0;
    end
    else if (W_wav_hdr && !S_cfg_seen) begin
        S_cfg_tog  <= ~S_cfg_tog;
        S_cfg_seen <= 1'b1;
    end
    else if (!W_wav_hdr) begin
        S_cfg_seen <= 1'b0;
    end
end

reg [2:0] S_cfg_sync;
always @(posedge I_mclk or posedge I_mclk_rst) begin
    if (I_mclk_rst) S_cfg_sync <= 3'b000;
    else            S_cfg_sync <= {S_cfg_sync[1:0], S_cfg_tog};
end
wire W_cfg_load = (S_cfg_sync[2] != S_cfg_sync[1]);

reg [31:0] S_sr, S_ftotal;
always @(posedge I_mclk or posedge I_mclk_rst) begin
    if (I_mclk_rst) begin
        S_sr     <= 32'd48000;
        S_ftotal <= 32'd0;
    end
    else if (W_cfg_load) begin
        S_sr     <= W_wav_sr;
        S_ftotal <= W_wav_ftotal;
    end
end

/* ======================================================================== */
/* 5. 帧节拍 + 播放控制器（MCLK 域）                                         */
/* ======================================================================== */
wire             W_pcm_valid;
wire [23:0]      W_pcm_left, W_pcm_right;
wire             W_frame_stb;

pcm_frame_tick u_pcm_frame_tick (
    .I_mclk      (I_mclk),
    .I_rst       (I_mclk_rst),
    .O_frame_stb (W_frame_stb)
);

pcm_player #(
    .MCLK_HZ  (MCLK_HZ),
    .FIFO_addr_bits  (FIFO_addr_bits)
) u_pcm_player (
    .I_clk         (I_mclk),
    .I_rst         (I_mclk_rst),
    .I_play        (I_play),
    .I_stop        (W_stop_m),
    .I_sample_rate (S_sr),
    .I_frame_total (S_ftotal),
    .I_frame_stb   (W_frame_stb),
    .O_fifo_rd     (W_fifo_rd),
    .I_fifo_data   (W_fifo_rdata),
    .I_fifo_valid  (W_fifo_rvalid),
    .I_fifo_empty  (W_fifo_empty),
    .I_fifo_level  (W_fifo_level),
    .O_pcm_valid   (W_pcm_valid),
    .O_pcm_left    (W_pcm_left),
    .O_pcm_right   (W_pcm_right),
    .O_play_pos    (O_play_pos),
    .O_end         (O_play_end),
    .O_underrun    (O_underrun),
    .O_underrun_cnt(O_underrun_cnt),
    .O_buf_level   (O_buf_level),
    .O_empty       ()
);

/* ======================================================================== */
/* 5.5 训练模式心跳：音频口的 2:1 多路选择器（MCLK 域，2026-10-25）           */
/* ------------------------------------------------------------------------ */
/* 为什么放在 pcm_player 之后、toggle 跨域之前：                              */
/*   * 心跳必须和 WAV 用**同一个帧节拍**（W_frame_stb）。两路各自分频的话，    */
/*     48 kHz 名义相同、实际差一点点，切换音源那一帧就会多/少一个样本，       */
/*     听感是"咔"的一下爆音；放在这里两者天然同拍，切换只是换数据源。          */
/*   * ACR（N/CTS）是数 O_audio_valid 的，只要 valid 节拍不断，切换音源       */
/*     对 HDMI 音频流完全透明。pcm_player 无论播/停都每帧发一个 valid，       */
/*     所以训练模式即使不读卡，音频流也不会断。                               */
/*                                                                          */
/* 就是一条二选一（2026-10-25 第五次改）：                                    */
/*     I_heart_en = 0  →  该页 WAV（教学 / 展播，逐位等于 pcm_player 输出）    */
/*     I_heart_en = 1  →  heartbeat_synth 的"咚—哒"（训练模式）               */
/*   训练模式下该页音频被完全屏蔽 —— 选择器根本不选它，不是把它压成 0 再相加。 */
/*   混音（WAV+心跳）、两段 2 ms 斜坡、heart_mix_stage、audio_crossfade 全部   */
/*   删除，只保留"功能能跑通"这一条路。切换那一帧是硬切，理论上有一声咔哒；    */
/*   要消掉它就得把淡化加回来（见 docs/heartbeat-synth-implementation.md）。  */
/*                                                                          */
/* I_mute 只留给 SW4 暂停：它是 WAV 这一路自己的闸，和选择器无关。            */
/*                                                                          */
/* 2026-10-26 改了两处：                                                      */
/*   1) I_heart_en / I_mute 都是 video_clk（25.175 MHz）过来的电平，本模块跑  */
/*      MCLK（12.288 MHz）。原来直接拿来驱动选择器和 ~120 个 FF 的内部状态，  */
/*      单 bit 被判成不同值的机会很小但存在，而且 project_cdc.sdc 的举证里    */
/*      写的是"跨域只有 FIFO 和两级同步"——加了心跳以后这句话就不成立了。      */
/*      现在两者各过两级同步器，sel / I_mute 都取同步后的 W_heart_m /          */
/*      W_mute_m。                                                          */
/*   2) sel 不再等于 I_heart_en，而是 (W_heart_m | O_busy)：退出训练那一刻     */
/*      心跳可能正响着，heartbeat_synth 会在 0.7 ms 内把包络压到 0 并保持      */
/*      O_busy=1，选择器等它收完尾再切回 WAV，避免"满幅中途截断"的爆音。       */
/*      收尾完之后心跳输出恒 0，切点上只剩"WAV 侧此刻的幅度"这一个阶跃，       */
/*      与 SW4 暂停/继续的硬闸同一量级（要彻底消掉得加增益斜坡，见文档 §12）。 */
/* ======================================================================== */
wire signed [23:0] W_hb_l, W_hb_r;
wire               W_hb_busy;

// ---- 控制位跨域：video_clk → MCLK（两级同步，电平量，按住是毫秒级） ----
reg [1:0] S_heart_sync;
reg [1:0] S_mute_sync;
always @(posedge I_mclk or posedge I_mclk_rst) begin
    if (I_mclk_rst) begin
        S_heart_sync <= 2'b00;
        S_mute_sync  <= 2'b00;
    end
    else begin
        S_heart_sync <= {S_heart_sync[0], I_heart_en};
        S_mute_sync  <= {S_mute_sync[0],  I_mute};
    end
end
wire W_heart_m = S_heart_sync[1];
wire W_mute_m  = S_mute_sync[1];

heartbeat_synth #(
    .MCLK_HZ (MCLK_HZ)
) u_heartbeat (
    .I_clk       (I_mclk),
    .I_rst       (I_mclk_rst),
    .I_frame_stb (W_frame_stb),
    .I_enable    (W_heart_m),
    .O_busy      (W_hb_busy),
    .O_left      (W_hb_l),
    .O_right     (W_hb_r)
);

// WAV 这一路只过 SW4 暂停闸（I_mute）：暂停时发 0，但帧节拍照走。
wire signed [23:0] W_wav_l = W_mute_m ? 24'sd0 : $signed(W_pcm_left);
wire signed [23:0] W_wav_r = W_mute_m ? 24'sd0 : $signed(W_pcm_right);

// ---- 二选一多路选择器 ----------------------------------------------------
// sel = 训练模式或心跳还在收尾：1 → 心跳，0 → WAV。两位一起选，左右不会错位。
wire W_sel = W_heart_m | W_hb_busy;
wire signed [23:0] W_out_l = W_sel ? W_hb_l : W_wav_l;
wire signed [23:0] W_out_r = W_sel ? W_hb_r : W_wav_r;

/* ======================================================================== */
/* 6. PCM 直连：MCLK 域 → 像素时钟域                                         */
/* ------------------------------------------------------------------------ */
/* 跨域用"数据 + 翻转标志"（toggle handshake），不用异步 FIFO：              */
/*   * MCLK 域：每次 O_pcm_valid 更新 {R,L}，同一拍翻转 S_tog；               */
/*   * 像素域：3 级同步 S_tog，检测到翻转就认为"这一帧数据已稳定"；          */
/*   * 时间余量：数据与标志同拍变化，标志要 2~3 个 video_clk（80~120 ns）才被    */
/*     检出，而数据要 20.8 µs 后才换成下一帧 —— 采样点落在数据稳定区正中，      */
/*     不存在"贴着串行位边沿采"的问题。                                      */
/*   * 一拍只能送一帧：帧率 48 kHz、video_clk 25.175 MHz，两次翻转之间隔       */
/*     524 个像素时钟，3 级同步器早就稳定了，不会漏帧（TB 里量了这个间隔）。   */
/* ======================================================================== */
reg        S_tog;        // MCLK 域：每收一帧翻转
reg [47:0] S_frame_m;    // MCLK 域：{R[23:0], L[23:0]}，与 S_tog 同拍更新

always @(posedge I_mclk or posedge I_mclk_rst) begin
    if (I_mclk_rst) begin
        S_tog     <= 1'b0;
        S_frame_m <= 48'd0;
    end
    else if (W_pcm_valid) begin
        // 静音 → 选择/混音 → 一次锁进跨域寄存器
        S_frame_m <= {W_out_r, W_out_l};
        S_tog     <= ~S_tog;
    end
end

reg [2:0] S_tog_sync;    // 像素域：3 级同步（后两级做边沿检测）
always @(posedge I_video_clk or posedge I_video_rst) begin
    if (I_video_rst) S_tog_sync <= 3'b000;
    else             S_tog_sync <= {S_tog_sync[1:0], S_tog};
end

wire W_frame_new = S_tog_sync[2] ^ S_tog_sync[1];   // 单拍：新的一帧到了

reg        S_aud_valid;
reg [47:0] S_aud_frame;
always @(posedge I_video_clk or posedge I_video_rst) begin
    if (I_video_rst) begin
        S_aud_valid <= 1'b0;
        S_aud_frame <= 48'd0;
    end
    else begin
        S_aud_valid <= W_frame_new;         // valid 与数据同拍寄存，保证对齐
        if (W_frame_new) S_aud_frame <= S_frame_m;
    end
end

assign O_audio_valid      = S_aud_valid;
assign O_audio_left_data  = S_aud_frame[23 -: pcm_bits];   // 24 bit 左对齐取高位
assign O_audio_right_data = S_aud_frame[47 -: pcm_bits];

audio_arc_calculate #(
    .ACR_N (ACR_N)
) u_acr (
    .I_clk         (I_video_clk),
    .I_rst         (I_video_rst),
    .I_audio_valid (O_audio_valid),
    .O_acr_valid   (O_acr_valid),
    .O_acr_cts     (O_acr_cts),
    .O_acr_n       (O_acr_n)
);

/* ======================================================================== */
/* 7. 状态输出                                                              */
/* ======================================================================== */
assign O_wav_ready      = W_wav_hdr;
assign O_wav_error      = W_wav_err;
assign O_wav_error_code = W_wav_ecode;
assign O_wav_state      = W_wav_state;
assign O_file_size      = W_wav_fsz;
assign O_sample_rate    = W_wav_sr;
assign O_channels       = W_wav_ch;
assign O_bits           = W_wav_bits;
assign O_data_bytes     = W_wav_dbytes;
assign O_frame_total    = W_wav_ftotal;
assign O_sector_cnt     = W_wav_scnt;
assign O_frame_cnt      = W_wav_fcnt;

endmodule
