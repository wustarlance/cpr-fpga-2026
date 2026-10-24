# ADC-only coherent sample transfer. Loaded by build.tcl for top_adc.
# src_hold remains stable until destination capture and acknowledgement.
# Request crosses two synchronizer stages and one pending capture cycle.
# Bound the coherent bus to one 25 MHz destination period (40 ns).
# Endpoint count checks remain in build.tcl; replayable SDC uses inline queries.
set_max_delay -from [get_regs {*u_mailbox/src_hold[*]}] -to [get_regs {*u_mailbox/dst_data[*]}] 40 -datapath_only
set_false_path -to [get_regs {*u_mailbox/req_meta}]
set_false_path -to [get_regs {*u_mailbox/ack_meta}]
set_false_path -to [get_regs {*u_sensor/fault_meta}]
