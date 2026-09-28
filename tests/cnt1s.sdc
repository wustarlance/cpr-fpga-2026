# ============================================================================
# cnt1s.sdc —— 时序约束文件（SDC = Synopsys Design Constraints）
#
# 作用：告诉 TD 综合/布局布线工具"这个设计的时钟有多快"。
#       没有这个文件，TD 就不知道 CLOCK 的周期，会报：
#         TMST-7700  CRITICAL-WARNING: 2 SEVERE timing constraint issue(s)
#       并在检查报告里列出：
#         checking nets with no clock driven → CLOCK / CLOCK_dup_1
#
# 板级信息：HX4S20C 的板载有源晶振为 50MHz
#           周期 = 1 / 50MHz = 20ns
#           占空比 50% → 上升沿在 0ns，下降沿在 10ns，故波形为 {0 10}
# ============================================================================

create_clock -name CLOCK -period 20 -waveform {0 10} [get_ports {CLOCK}]

# ----------------------------------------------------------------------------
# 说明
# ----------------------------------------------------------------------------
# 1. 端口名必须和 Verilog 顶层端口一致，本工程是 CLOCK（全大写）。
# 2. 本工程目前没有 PLL，所以不需要 derive_clocks 和 rename_clock。
#    等以后用上 PLL（比如 HDMI 的像素时钟），再按参考例程
#    lab_ex5_i2s/.../constraints_source/timing.sdc 的写法补上：
#        derive_clocks
#        rename_clock -name {video_clk} -source [get_ports {clk}] \
#                     -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[0]}]
# 3. 本工程的 rst_n 和 LED 没有加 input/output delay 约束，
#    TD 会报 MEDIUM 级提示（检查报告第 10、11 项），不是错误。
#    LED 是慢速信号，rst_n 是按钮，都不需要。等接了高速外设再补。
