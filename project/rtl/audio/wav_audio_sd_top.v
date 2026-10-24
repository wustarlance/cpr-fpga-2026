`timescale 1ns/1ps
//=============================================================================
// wav_audio_sd_top.v —— 上板用的一层皮：SD 扇区读口 + wav_audio_path
//-----------------------------------------------------------------------------
// 分工（2026-10-22 改为"一份 SD 控制器"方案）：
//   sd_card_top    **不在本文件里**。统一框架里只保留一份 SD 控制器，
//                  由它驱动 SPI 引脚，本层只接它的扇区读从接口。
//   wav_audio_path 只管"怎么读 → 怎么放 → 怎么直接送 HDMI（ACR 自带）"，
//                  另有 I2S 三线可引到引脚做观测，但不参与 HDMI 数据
//
// 所以本层不再有 SD_nCS/SD_DCLK/SD_MOSI/SD_MISO，也没有 SPI 分频参数。
// 上板时在框架顶层这样接（只有一份 sd_card_top）：
//
//   sd_card_top u_sd ( ... .sd_init_done      (W_sd_init_done),
//                          .sd_sec_read        (W_sec_read),
//                          .sd_sec_read_addr   (W_sec_addr),
//                          .sd_sec_read_data   (W_sec_data),
//                          .sd_sec_read_data_valid (W_sec_valid),
//                          .sd_sec_read_end    (W_sec_end) );
//
//   wav_audio_sd_top u_audio ( ... .I_sd_init_done  (W_sd_init_done),
//                                  .O_sd_sec_addr   (W_sec_addr),
//                                  .O_sd_sec_read   (W_sec_read),
//                                  .I_sd_sec_data   (W_sec_data),
//                                  .I_sd_sec_valid  (W_sec_valid),
//                                  .I_sd_sec_end    (W_sec_end) );
//
// 时钟（与参考工程一致，三个域都要给）：
//   I_sd_clk     100 MHz    sys_pll clk0
//   I_mclk       12.288 MHz PLL_HDMI_AUDIO（工程实际 12.295082 → fs 48027 Hz）
//   I_video_clk  25.175 MHz video_pll clk0 = 像素时钟
//
// 复位：三个域各一个，建议都接到 reset_release 的输出（各自同步释放），
// 高有效。
//
// 典型接法：
//   .O_audio_valid / O_audio_left_data / O_audio_right_data → HDMI 核 I_audio_*
//   .O_acr_valid / O_acr_cts / O_acr_n                      → HDMI 核 I_acr_*
//   ACR 已在本层算好，框架里原来的 audio_arc_calculate 可以不例化。
//
// 起始扇区是**参数**，不是常量散在代码里：
//   parameter START_SECTOR = 32'd12000  ← 唯一一处定义
//   12000 是为了和 scaling-test 的 BMP 镜像（占 LBA 0 ~ 11853）共存，
//   BMP 镜像从扇区 0 开始写，会覆盖 MBR，所以音频只能放在它后面。
//   tools/burn_wav.py 会从这个文件里读这个值当默认 --lba，两边不会不一致。
//   要运行时改（按键选曲），把 wav_audio_path 的 I_start_sector 引出来即可，
//   本层不加第二个配置口，避免"参数和端口谁优先"的歧义。
//
// 与厂商 sd_card_top 的接口边界（2026-10-21 修正）：
//   厂商原文件只有 sd_sec_read(电平请求) / sd_sec_read_end(结束) / data_valid，
//   **没有** ready、read_error、read_cancel，也没有 TOKEN/SPI 超时参数。
//   所以本层把 ready 常量 1、error 常量 0 接进去；真正的出错检测靠
//   wav_reader 自己的 WAIT_TIMEOUT_CYCLES（1 s 无进展 → ERR_TIMEOUT）。
//=============================================================================
module wav_audio_sd_top #(
    parameter [31:0]  START_SECTOR        = 32'd12000, // WAV 文件首扇区（LBA）
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
    input  wire        I_play,
    input  wire        I_stop,
    input  wire        I_mute,
    input  wire        I_loop,

    /* ---- SD 扇区读从接口（接框架里唯一那份 sd_card_top，只读不写） ---- */
    input  wire        I_sd_init_done,
    output wire [31:0] O_sd_sec_addr,
    output wire        O_sd_sec_read,
    input  wire [7:0]  I_sd_sec_data,
    input  wire        I_sd_sec_valid,
    input  wire        I_sd_sec_end,

    /* ---- I2S 三线已删除（2026-10-22）：HDMI 走 PCM 直连，无需串行口 ---- */

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
    .I_sd_sec_ready  (1'b1),          // 厂商控制器无 ready，恒 1（bmp_read 也是立即发请求）
    .I_sd_sec_data   (I_sd_sec_data),
    .I_sd_sec_valid  (I_sd_sec_valid),
    .I_sd_sec_end    (I_sd_sec_end),
    .I_sd_sec_error  (1'b0),          // 无错误线；靠 reader 内部 1 s 超时兜底
    .O_sd_sec_addr   (O_sd_sec_addr),
    .O_sd_sec_read   (O_sd_sec_read),

    .I_start_sector  (START_SECTOR),

    .I_mclk          (I_mclk),
    .I_mclk_rst      (I_mclk_rst),
    .I_video_clk     (I_video_clk),
    .I_video_rst     (I_video_rst),

    .I_play          (I_play),
    .I_stop          (I_stop),
    .I_mute          (I_mute),
    .I_loop          (I_loop),

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
