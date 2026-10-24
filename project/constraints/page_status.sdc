# Coherent 100 MHz SD -> 25 MHz video status, held until capture and ACK.
# After optimize_rtl, require exactly 12 registers at each end in build.tcl.
# Keep endpoint queries inline: TD retains/replays these SDC expressions when
# changing netlist stages; Tcl variable names are not persistent SDC objects.
set_max_delay -from [get_regs {*u_page_status/u_transfer/src_hold[*]}] -to [get_regs {*u_page_status/u_transfer/dst_data[*]}] 40 -datapath_only
set_false_path -to [get_regs {*u_page_status/u_transfer/req_meta}]
set_false_path -to [get_regs {*u_page_status/u_transfer/ack_meta}]
