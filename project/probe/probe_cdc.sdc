# 探针自带的跨域例外：ADC 域按 EOC 抓的 dout，1 Hz 搬到 50 MHz 显示域。
# 这个值在两次转换之间（约 5 us）稳定，1 Hz 采一次，只需一个宽松的数据路径预算。
set_max_delay -from [get_regs -nowarn {*adc_dout_at_eoc[*]}] \
              -to   [get_regs -nowarn {*adc_dout_disp[*]}] 40 -datapath_only
