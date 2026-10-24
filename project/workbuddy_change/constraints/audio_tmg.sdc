# =============================================================================
# audio_tmg.sdc —— audio_tmg_top 的时序约束（独立综合工程，非上板约束）
#
# 三个时钟直接由端口给，不经 PLL：
#   100.000 MHz  SD 扇区读 + wav_reader（最紧）
#    12.288 MHz  48 kHz 帧节拍
#    25.175 MHz  像素时钟（PCM 输出 + ACR + 波形绘制）
#
# 三者确实异步（SD 卡与像素时钟无固定相位关系，MCLK 来自另一颗 PLL），
# 所以用 set_clock_groups 一刀切开。跨域点全部是构造性正确的：
#   pcm_fifo  = 格雷码指针 + 2 级同步
#   toggle    = 电平/翻转标志 + 3 级同步
#   SD 状态   = 准静态，非周期采样
# 打开 -asynchronous 后这些路径不再逐条卡建立/保持，这正是它们的设计前提。
# =============================================================================

create_clock -name sd_clk  -period 10.000 -waveform {0 5.000}   [get_ports I_sd_clk]
create_clock -name mclk    -period 81.380 -waveform {0 40.690}  [get_ports I_mclk]
create_clock -name vid_clk -period 39.722 -waveform {0 19.861}  [get_ports I_video_clk]

set_clock_groups -name async_domains -asynchronous \
    -group {sd_clk} -group {mclk} -group {vid_clk}

# ---- SD 卡 4 根 SPI 线 ----
# SD SPI 实际只跑 25 MHz（= sd_clk/((0+2)*2)），而驱动这几根线的寄存器都在
# sd_clk 域。若按 10 ns 周期 + 5 ns output delay 硬卡，光输出 pad 自身的
# clk→pad 延迟就超过半个周期，必然"违例"——那是约束错，不是电路错。
# 卡在 SD_DCLK 边沿采样，相对 sd_clk 是 4 个周期的多周期路径。
set_output_delay 5.0 -clock sd_clk [get_ports {O_sd_ncs O_sd_dclk O_sd_mosi}]
set_multicycle_path 4 -setup -to [get_ports {O_sd_ncs O_sd_dclk O_sd_mosi}]
set_multicycle_path 3 -hold  -to [get_ports {O_sd_ncs O_sd_dclk O_sd_mosi}]

set_input_delay  5.0 -clock sd_clk [get_ports I_sd_miso]
set_multicycle_path 4 -setup -from [get_ports I_sd_miso]
set_multicycle_path 3 -hold  -from [get_ports I_sd_miso]

# ---- 送 HDMI 核的音频口（真机上这些是片内连线，这里引 pad 后给 3 ns） ----
set_output_delay 3.0 -clock vid_clk [get_ports {O_audio_valid O_audio_l[*] O_audio_r[*] O_acr_valid O_acr_cts[*] O_acr_n[*]}]

# ---- 波形绘制输出（真机上接视频混叠级，同样片内） ----
set_output_delay 3.0 -clock vid_clk [get_ports {O_pix_hit O_pix_rgb[*] O_pix_de_d}]

# ---- 准静态输入 / 诊断口 ----
set_false_path -from [get_ports {I_ctrl[*] I_rst_n}]
set_false_path -to   [get_ports {O_dbg[*]}]
