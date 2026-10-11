# HX4S20C V1.0, 50 MHz input. Both tops use these same PLLs.
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]
derive_clocks
rename_clock -name sd_card_clk -source [get_ports {clk}] -master_clock clk [get_pins {*sys_pll_m0/pll_inst.clkc[0]}]
rename_clock -name ext_mem_clk -source [get_ports {clk}] -master_clock clk [get_pins {*sys_pll_m0/pll_inst.clkc[1]}]
rename_clock -name video_clk -source [get_ports {clk}] -master_clock clk [get_pins {*video_pll_m0/pll_inst.clkc[0]}]
rename_clock -name hdmi_5x_clk -source [get_ports {clk}] -master_clock clk [get_pins {*video_pll_m0/pll_inst.clkc[1]}]
rename_clock -name audio_mclk -source [get_ports {clk}] -master_clock clk [get_pins {*u_audio_pll/pll_inst.clkc[2]}]

# Pixel/serial clocks operate simultaneously and remain related. Preserve
# generated FIFO Gray-pointer bounds: no broad clock-group exceptions.
# Never relax SDRAM DQ timing based on the user-port read latency.

# ADC mailbox exceptions live in adc_mailbox.sdc. build.tcl loads that file
# only for top_adc, after checking the elaborated registers. Keeping it
# separate avoids TD replaying ADC-only constraints in the board-demo top.
# External input delay and HDMI sink/SD timing require bench measurements
# for physical signoff. Placement/routing and setup/hold are not proven here.
