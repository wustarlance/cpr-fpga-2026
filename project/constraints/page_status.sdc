# Coherent 100 MHz SD -> 25 MHz video status, held until capture and ACK.
# After optimize_rtl, require exactly 12 registers at each end in build.tcl.
set cpr_page_hold [get_regs {*u_page_status/u_transfer/src_hold[*]}]
set cpr_page_capture [get_regs {*u_page_status/u_transfer/dst_data[*]}]
set_max_delay -from $cpr_page_hold -to $cpr_page_capture 40 -datapath_only
set_false_path -to [get_regs {*u_page_status/u_transfer/req_meta}]
set_false_path -to [get_regs {*u_page_status/u_transfer/ack_meta}]
