`timescale 1ns/1ps
// 音频读卡与播放封装：选曲、PCM通路及HDMI ACR输出。
// SD控制器在顶层，由sd_sec_arbiter与BMP共享；本模块仅使用扇区读接口。
// I_audio_sel的0..3选教程WAV，4选自动展播背景曲；首LBA见wav_track_select。
// 选曲变化走abort/start，重新锁存首扇区并清FIFO；暂停状态保持。
// I_heart_en选择片内合成心跳，训练时无需读取WAV。
// 三个时钟域分别为SD、MCLK和视频，复位由上层各域同步释放。
// PCM帧率为MCLK/256。O_audio_*和O_acr_*直接连接HDMI核。
// 扇区ready来自仲裁器，错误输入固定0，读取超时由wav_reader检测。
module wav_audio_sd_top #(
    parameter integer MCLK_HZ                          = 12_288_000,
    parameter integer pcm_bits                         = 24,        // 送 HDMI 核的样本位宽
    parameter integer FIFO_DEPTH                       = 1024,      // 缓冲帧数（1 帧 = 48 bit）
    parameter integer FIFO_addr_bits                   = 10,        // 必须 = log2(FIFO_DEPTH)
    parameter integer ACR_N                            = 6144       // HDMI 规范表：48k→6144、44.1k→6272
)(
    /* ---- 时钟 / 复位 ---- */
    input  wire        I_sd_clk,
    input  wire        I_mclk,
    input  wire        I_video_clk,
    input  wire        I_sd_rst,          
    input  wire        I_mclk_rst,
    input  wire        I_video_rst,

    /* ---- 控制 ---- */
    input  wire [2:0]  I_audio_sel,         // 选曲：0..3 → PICTURE_1..4；4 → FREE_SONG
    input  wire        I_play,              // 1 = 播放；0 = 暂停（位置保留，不消耗 FIFO）
    input  wire        I_stop,              // 单拍：回到当前曲目开头
    input  wire        I_mute,
    input  wire        I_loop,
    input  wire        I_heart_en,          // 音频口 2:1 选择：0 = 该页 WAV，1 = 心跳

    /* ---- SD 扇区读从接口（接框架里唯一那份 sd_card_top，只读不写） ---- */
    input  wire        I_sd_init_done,
    input  wire        I_sd_sec_ready,      // 总线空闲可发请求（来自 sd_sec_arbiter）
    output wire [31:0] O_sd_sec_addr,
    output wire        O_sd_sec_read,
    input  wire [7:0]  I_sd_sec_data,
    input  wire        I_sd_sec_valid,
    input  wire        I_sd_sec_end,

    /* ---- 送 HDMI 1.4b 核 ---- */
    output wire                    O_audio_valid,
    output wire [pcm_bits-1:0]     O_audio_left_data,
    output wire [pcm_bits-1:0]     O_audio_right_data,
    output wire                    O_acr_valid,
    output wire [19:0]             O_acr_cts,
    output wire [19:0]             O_acr_n,

    /* ---- 状态 / 诊断 ---- */
    output wire        O_wav_ready,
    output wire        O_wav_error,
    output wire [3:0]  O_wav_error_code,
    output wire [3:0]  O_wav_state,
    output wire [31:0] O_file_size,
    output wire [31:0] O_sample_rate,
    output wire [15:0] O_channels,
    output wire [15:0] O_bits,
    output wire [31:0] O_frame_total,
    output wire [31:0] O_play_pos,
    output wire        O_play_end,
    output wire [FIFO_addr_bits:0] O_buf_level,
    output wire        O_underrun
);

/* ------------------------------------------------------------------------ */
/* 选曲：页号 → 首扇区；换页那一拍自动重启读取                                */
/* ------------------------------------------------------------------------ */
wire [31:0] W_track_sector;
wire        W_track_changed;

// 使用wav_track_select的默认扇区表。
wav_track_select u_track (
    .I_clk       (I_sd_clk),
    .I_rst       (I_sd_rst),
    .I_audio_sel (I_audio_sel),
    .O_sector    (W_track_sector),
    .O_changed   (W_track_changed)
);

// 外部停止和换曲共用abort/start。暂停时换页，恢复后从新曲开头播放。
wire W_path_stop = I_stop | W_track_changed;

/* ------------------------------------------------------------------------ */
/* WAV 音频通路                                                              */
/* ------------------------------------------------------------------------ */
wav_audio_path #(
    .MCLK_HZ  (MCLK_HZ),
    .pcm_bits  (pcm_bits),
    .FIFO_DEPTH (FIFO_DEPTH),
    .FIFO_addr_bits  (FIFO_addr_bits),
    .ACR_N    (ACR_N)
) u_path (
    .I_sd_clk        (I_sd_clk),
    .I_sd_rst        (I_sd_rst),
    .I_sd_init_done  (I_sd_init_done),
    .I_sd_sec_ready  (I_sd_sec_ready),  // 由顶层仲裁器给出：BMP 占用时拉低，WAV 自动等
    .I_sd_sec_data   (I_sd_sec_data),
    .I_sd_sec_valid  (I_sd_sec_valid),
    .I_sd_sec_end    (I_sd_sec_end),
    .I_sd_sec_error  (1'b0),          // 无错误线；靠 reader 内部 1 s 超时兜底
    .O_sd_sec_addr   (O_sd_sec_addr),
    .O_sd_sec_read   (O_sd_sec_read),

    .I_start_sector  (W_track_sector),

    .I_mclk          (I_mclk),
    .I_mclk_rst      (I_mclk_rst),
    .I_video_clk     (I_video_clk),
    .I_video_rst     (I_video_rst),

    .I_play          (I_play),
    .I_stop          (W_path_stop),
    .I_mute          (I_mute),
    .I_loop          (I_loop),
    .I_heart_en      (I_heart_en),

    .O_audio_valid      (O_audio_valid),
    .O_audio_left_data  (O_audio_left_data),
    .O_audio_right_data (O_audio_right_data),
    .O_acr_valid        (O_acr_valid),
    .O_acr_cts          (O_acr_cts),
    .O_acr_n            (O_acr_n),

    .O_wav_ready     (O_wav_ready),
    .O_wav_error     (O_wav_error),
    .O_wav_error_code(O_wav_error_code),
    .O_wav_state     (O_wav_state),
    .O_file_size     (O_file_size),
    .O_sample_rate   (O_sample_rate),
    .O_channels      (O_channels),
    .O_bits          (O_bits),
    .O_data_bytes    (),
    .O_frame_total   (O_frame_total),
    .O_play_pos      (O_play_pos),
    .O_play_end      (O_play_end),
    .O_buf_level     (O_buf_level),
    .O_underrun      (O_underrun),
    .O_underrun_cnt  (),
    .O_sector_cnt    (),
    .O_frame_cnt     ()
);

endmodule
