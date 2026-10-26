#=============================================================================
# project_cdc.sdc —— 总工程 top 的多时钟域关系（2026-10-24 新增）
#-----------------------------------------------------------------------------
# 为什么需要这个文件：
#   把 SD 卡 WAV 播放接进总工程后，音频主时钟（u_audio_pll/pll_inst.clkc[2]，
#   12.296 MHz）第一次与 sd_card_clk / video_clk 之间出现实际路径。
#   原 constraints/timing.sdc 明确写了"不做宽泛的 clock group 例外"，于是 TD 按
#   同步关系去算这些跨域路径，报出：
#       sd_card_clk -> audio   SWNS -2.347ns（32 端点）
#       video_clk   -> audio   SWNS -1.870ns（75 端点）
#       audio       -> sd      HWNS -1.540ns（保持）
#       video_clk   -> sd      HWNS -1.327ns（保持）
#       video_clk   -> ext_mem HWNS -1.528ns（保持）
#   这些负 slack 不是逻辑算不过来，而是**相位关系本就不存在**：
#   各 PLL 输出虽然同源于 50 MHz 参考，但相位无关，跨域点全部是构造性安全的。
#
# 举证（逐条对照 route_timing_summary.rpt 的路径端点）：
#   frame_read_write/read_buf/rd_to_wr_cross_inst/primary_addr_gray_reg
#       -> sync_r1_reg      ：格雷码指针 + 两级同步器（标准异步 FIFO 跨域）
#   u_audio_wav 侧全部跨域：PCM 数据过双时钟 FIFO；I_loop 经两级同步；
#                           WAV 头信息（采样率/总帧数）解析后保持恒定，
#                           只在停止/重新开文件时更新一次
#   u_audio_wav/u_heartbeat 的训练模式选择端（2026-10-26 补）：
#       video_clk 域的 I_heart_en / I_mute 进入音频块后各过一级两级同步器
#       （S_heart_sync / S_mute_sync，见 rtl/audio/wav_audio_path.v §5.5），
#       同步后的 W_heart_m / W_mute_m 才去驱动选择器和心跳模块；
#       心跳模块的 O_busy 是 MCLK 域内部信号，不跨域。
#       注意：这两个是**电平**（按下/切模式后保持毫秒级），不是单拍脉冲，
#       两级同步足够；真正的单拍跨域（I_stop）走 toggle 握手，不在这里。
#   保持（HWNS）违例全部落在同步器的第一级输入上，两级同步器本身就能吸收，
#   没有实际意义。
#
#   选曲码 I_audio_sel（2026-10-26 由 2 bit 扩到 3 bit，加第 5 段 FREE_SONG）：
#       0..3 来自 ext_mem_clk 域的 active_read_idx，bit2 来自 video_clk 域的
#       auto_mode_q（app_mode==1 打一拍）。两者都不是格雷码，跳变时可能有多位
#       同时翻转，所以 wav_audio_sd_top/u_track_select 里先 2 级同步、再做
#       "连续 8 拍不变才认"的稳定过滤（S_sel_cnt），中间值活不过一拍，被直接
#       滤掉；确认后才产生一次 abort→start。也就是说这条跨域不是靠"多位同时
#       稳定"保证的，而是靠**时间过滤**（8 个 100 MHz 周期 = 80 ns，远小于
#       一次换页的毫秒级间隔），和 frame_fifo 的格雷码指针是两种不同手段。
#
# 保留检查的部分：
#   - 每个时钟域内部的单域路径（含 sd_card_clk 内 -0.602ns 那条，
#     它是 frame_read_write -> bmp_read 的实际长路径，不是跨域问题）
#   - video_clk 与 hdmi_5x_clk 仍放在同一组，像素/串行时钟关系保持不变
#   - clk（50 MHz 输入）不纳入分组，输入建立/保持照旧检查
#=============================================================================

# 音频 PLL 输出时钟：derive_clocks 生成的时钟名带实例层次路径——top 下是
# u_audio_pll/pll_inst.clkc[2]，top_adc 下多一层 u_board/。这条精确名只能命中
# 其中一个顶层，命中不到时 $audio_clk 为空，set_clock_groups 就少一组，音频
# 时钟退回同步关系：top_adc 因此报出 audio -> sd 的 -6.129ns 假违例（时钟表里
# 该路径预算只剩 0.662ns，明显是拿两个无公倍关系的周期硬配边沿）。
# 用前导通配匹配两种层次，并在空匹配时直接报错，不允许静默失效。
set audio_clk [get_clocks {*audio_pll/pll_inst.clkc[2]}]
if {[llength $audio_clk] == 0} {
    error "project_cdc.sdc: audio PLL output clock not found (*audio_pll/pll_inst.clkc\[2\])"
}

set_clock_groups -name async_domains -asynchronous \
    -group [get_clocks {sd_card_clk}] \
    -group [get_clocks {ext_mem_clk ext_mem_clk_sft}] \
    -group [get_clocks {video_clk hdmi_5x_clk}] \
    -group $audio_clk
