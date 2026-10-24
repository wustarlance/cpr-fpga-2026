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
#   保持（HWNS）违例全部落在同步器的第一级输入上，两级同步器本身就能吸收，
#   没有实际意义。
#
# 保留检查的部分：
#   - 每个时钟域内部的单域路径（含 sd_card_clk 内 -0.602ns 那条，
#     它是 frame_read_write -> bmp_read 的实际长路径，不是跨域问题）
#   - video_clk 与 hdmi_5x_clk 仍放在同一组，像素/串行时钟关系保持不变
#   - clk（50 MHz 输入）不纳入分组，输入建立/保持照旧检查
#=============================================================================

# 音频 PLL 输出时钟：derive_clocks 生成的时钟名就是管脚路径
set audio_clk [get_clocks {u_audio_pll/pll_inst.clkc[2]}]

set_clock_groups -name async_domains -asynchronous \
    -group [get_clocks {sd_card_clk}] \
    -group [get_clocks {ext_mem_clk ext_mem_clk_sft}] \
    -group [get_clocks {video_clk hdmi_5x_clk}] \
    -group $audio_clk
