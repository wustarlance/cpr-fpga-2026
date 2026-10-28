# 探针自带的跨域例外：ADC 域的慢变值搬到 50 MHz 显示域。
# 这些值在两次转换之间（约 5 us）稳定，1 Hz 采一次，只需宽松的数据路径预算。
set_max_delay -from [get_regs -nowarn {*adc_dout_at_eoc[*]}] \
              -to   [get_regs -nowarn {*adc_dout_disp[*]}] 40 -datapath_only
set_max_delay -from [get_regs -nowarn {*ch_sel[*]}] \
              -to   [get_regs -nowarn {*ch_disp[*]}] 40 -datapath_only
set_max_delay -from [get_regs -nowarn {*dbg_dout_raw[*]}] \
              -to   [get_regs -nowarn {*dbg_dout_disp[*]}] 40 -datapath_only
