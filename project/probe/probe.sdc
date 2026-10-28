# 探针工程只需要最小时序：50 MHz 输入 + PLL 派生时钟（ADC 12.295082 MHz 自动派生）
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]
derive_clocks
