# =============================================================================
# audio_board.sdc —— audio_board_top 的时序约束（上板用）
#
# 时钟全部由 PLL 产生，所以先 create_clock 卡住 50 MHz 输入，再 derive_clocks
# 让 TD 自己生成三颗 PLL 的分频时钟，最后用 rename 给它们起可读的名字
# （与主工程 constraints/timing.sdc 同一套写法，报告里名字能对上）。
#
# 三个域确实异步：
#   sd_card_clk 100M ↔ audio mclk 12.295M : pcm_fifo 的格雷码指针 + 2 级同步
#   audio mclk  ↔ video_clk 25M           : toggle 标志 + 3 级同步
#   sd_card_clk ↔ video_clk               : 只有准静态状态位
# 这些跨域点都是构造性正确的（RTL 里就是按这个前提写的），所以用 clock_groups
# 一刀切开；逐条卡建立/保持既没有意义，也会掩盖真正的域内路径。
#
# video_clk 与 hdmi_5x_clk 必须保持相关（同为 video_pll 输出，5x 用于并串），
# 所以只把 sd_card_clk / audio mclk / video_clk 分成三组，不碰 hdmi_5x_clk。
# =============================================================================

create_clock -name clk -period 20.000 -waveform {0 10.000} [get_ports {clk}]
derive_clocks

# 用实例名绑定，便于报告里区分；名字与 RTL 里的 u_sys_pll / u_video_pll 一致
rename_clock -name sd_card_clk  -source [get_ports {clk}] -master_clock clk [get_pins {*u_sys_pll/pll_inst.clkc[0]}]
rename_clock -name video_clk    -source [get_ports {clk}] -master_clock clk [get_pins {*u_video_pll/pll_inst.clkc[0]}]
rename_clock -name hdmi_5x_clk  -source [get_ports {clk}] -master_clock clk [get_pins {*u_video_pll/pll_inst.clkc[1]}]
rename_clock -name audio_mclk   -source [get_ports {clk}] -master_clock clk [get_pins {*u_audio_pll/pll_inst.clkc[2]}]

# 三个域互异步（跨域点见文件头）。hdmi_5x_clk 故意留在组外，保持与 video_clk 相关。
set_clock_groups -name async_domains -asynchronous \
    -group {sd_card_clk} -group {video_clk} -group {audio_mclk}

# ---- TF 卡 SPI 四线 ----
# SPI 实际跑 25 MHz（= 100/((0+2)*2)），驱动寄存器在 100 MHz 域。
# 按 10 ns 硬卡会因 pad 自身 clk→out 延迟"违例"——那是约束错不是电路错。
# 卡在 SD_DCLK 边沿采样，相对 sd_card_clk 是 4 个周期的多周期路径。
set_output_delay 5.0 -clock sd_card_clk [get_ports {sd_ncs sd_dclk sd_mosi}]
set_multicycle_path 4 -setup -to [get_ports {sd_ncs sd_dclk sd_mosi}]
set_multicycle_path 3 -hold  -to [get_ports {sd_ncs sd_dclk sd_mosi}]

set_input_delay  5.0 -clock sd_card_clk [get_ports {sd_miso}]
set_multicycle_path 4 -setup -from [get_ports {sd_miso}]
set_multicycle_path 3 -hold  -from [get_ports {sd_miso}]

# ---- 异步输入：按键/拨码（RTL 内各有 2 级同步 + 20 ms 消抖） ----
set_false_path -from [get_ports {rst_n key_play key_stop key_mute dip_sw[*]}]

# ---- 指示输出：LED / 蜂鸣器（纯人眼/人耳，不参与任何反馈回路） ----
set_false_path -to [get_ports {led[*] O_buzzer}]
