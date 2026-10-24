# 按键测试只有 50 MHz 系统时钟（R7），没有 PLL，因此不引入产品的 timing.sdc。
create_clock -name clk -period 20.000 [get_ports clk]
