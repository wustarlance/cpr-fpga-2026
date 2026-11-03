`timescale 1ns/1ps
// WAV读取、PCM缓存、心跳选源与HDMI音频输出。
// SD域：wav_reader解析文件并写异步FIFO；MCLK域：按MCLK/256取样。
// WAV与心跳共用帧节拍，在MCLK域选源后以稳定数据和toggle送到视频域。
// 视频域根据音频valid计算ACR（N/CTS），PCM直接送HDMI核，不经过I2S回环。
// I_start_sector给出连续存放的WAV首LBA，本模块不扫描文件系统。
// 三个时钟及各域同步释放复位由上层提供，采样率随MCLK变化。
module wav_audio_path #(
    parameter integer MCLK_HZ             = 12_288_000,  // fs = MCLK/256
    parameter integer pcm_bits               = 24,          // 送 HDMI 核的样本位宽
    parameter integer FIFO_DEPTH          = 1024,
    parameter integer FIFO_addr_bits             = 10,
    parameter integer ACR_N               = 6144,        // N >> 7 = 6144 / 128 = 48;
    // 下面两个都是 **sd_clk 周期数**，不是 ns：
    //   100_000_000 周期 × 10 ns = 1 s（sd_clk = 100 MHz）
    parameter integer WAIT_TIMEOUT_CYCLES = 100_000_000, // 单扇区 1 s 无字节 → 超时
    // 读错误后的重试等待，单位为SD时钟周期。
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

    /* ---- MCLK时钟域 ---- */
    input  wire        I_mclk,
    input  wire        I_mclk_rst,        

    /* ---- 视频时钟域，接HDMI核 ---- */
    input  wire        I_video_clk,
    input  wire        I_video_rst,       

    /* ================= 控制 ================================================ */
    input  wire        I_play,            // 1 = 播放；0 = 暂停（发静音，不消耗 FIFO）
    input  wire        I_stop,            // 单拍：回到文件开头
    input  wire        I_mute,            // 1 = 静音（帧节拍照常走，样本清 0）；内部两级同步
    input  wire        I_loop,            // 1 = 单文件循环

    // 心跳在MCLK域与WAV二选一；退出时等待心跳包络收尾。
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
// Playback/mute are video-domain levels. Synchronize before MCLK use.
reg S_play_meta, S_play_sync, S_mute_meta, S_mute_sync;
always @(posedge I_mclk or posedge I_mclk_rst) begin
    if (I_mclk_rst) begin
        S_play_meta<=0; S_play_sync<=0;
        S_mute_meta<=1; S_mute_sync<=1;
    end else begin
        S_play_meta<=I_play; S_play_sync<=S_play_meta;
        S_mute_meta<=I_mute; S_mute_sync<=S_mute_meta;
    end
end
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

// 换曲先abort reader，再等待旧扇区end后重新解析。
// SD控制器接受扇区后会继续发送512字节；提前start会让旧数据/end进入新头部解析。
// abort等待期间也记录end，避免漏掉单拍结束。缺失end时由DRAIN_MAX限时退出。
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
// Snapshot with the toggle; reader reset/reparse must not change an in-flight payload.
reg [31:0] S_cfg_rate_hold, S_cfg_total_hold;
always @(posedge I_sd_clk or posedge I_sd_rst) begin
    if (I_sd_rst) begin
        S_cfg_tog  <= 1'b0;
        S_cfg_seen <= 1'b0;
        S_cfg_rate_hold<=0; S_cfg_total_hold<=0;
    end
    else if (W_wav_hdr && !S_cfg_seen) begin
        S_cfg_tog  <= ~S_cfg_tog;
        S_cfg_seen <= 1'b1;
        S_cfg_rate_hold<=W_wav_sr; S_cfg_total_hold<=W_wav_ftotal;
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
        S_sr     <= S_cfg_rate_hold;
        S_ftotal <= S_cfg_total_hold;
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
    .I_play        (S_play_sync),
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

// MCLK域选源：WAV与心跳共用W_frame_stb，保持音频valid及ACR节奏连续。
// I_heart_en经两级同步后选心跳；退出时保留选择直到W_hb_busy收尾结束。
// I_mute只静音WAV，不控制心跳。此处没有混音或交叉淡化，切回WAV可能有幅度阶跃。
wire signed [23:0] W_hb_l, W_hb_r;
wire               W_hb_busy;

// 心跳使能为视频域电平，经两级同步使用；静音复用S_mute_sync。
reg [1:0] S_heart_sync;
always @(posedge I_mclk or posedge I_mclk_rst) begin
    if (I_mclk_rst) S_heart_sync <= 2'b00;
    else            S_heart_sync <= {S_heart_sync[0], I_heart_en};
end
wire W_heart_m = S_heart_sync[1];
wire W_mute_m  = S_mute_sync;      // MCLK域同步静音电平

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

// PCM跨域：MCLK域更新48位样本并翻转S_tog，视频域三级同步后锁存。
// 源数据需保持到同步标志被接收；约48 kHz帧间隔远长于三个视频时钟。
// 若改变时钟或帧率，需重新核对两次toggle之间的最小间隔。
reg        S_tog;        // MCLK 域：每收一帧翻转
reg [47:0] S_frame_m;    // MCLK 域：{R[23:0], L[23:0]}，与 S_tog 同拍更新

always @(posedge I_mclk or posedge I_mclk_rst) begin
    if (I_mclk_rst) begin
        S_tog     <= 1'b0;
        S_frame_m <= 48'd0;
    end
    else if (W_pcm_valid) begin
        // 静音在两路各自处理：WAV 过 W_mute_m 闸，心跳由自己的包络收尾。
        // 这里只做二选一，然后一次锁进跨域寄存器（与 S_tog 同拍）。
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
