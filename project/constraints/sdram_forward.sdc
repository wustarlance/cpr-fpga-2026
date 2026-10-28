# Packed EG4 ODDR: D0=1, D1=0 reproduce the 40MHz / 135deg PLL waveform.
# Read only after legalize_phy_inst; both tops retain exactly one SDRAM PAD.
# No data-path exception, phase override, or external SDRAM delay replacement.
create_generated_clock -name sdram_forward_clk -source [get_pins {*sys_pll_m0/pll_inst.clkc[2]}] -master_clock ext_mem_clk_sft -divide_by 1 [get_pins {*U3/sdram_syn_45.opad}]
