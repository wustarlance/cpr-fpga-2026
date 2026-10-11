# The 50 MHz power-on readiness flag is a persistent level. Only the first
# stage of each two-flop readiness synchronizer is exempt; reset assertion,
# second-stage capture and downstream reset release/data paths remain timed.
set_false_path -from [get_regs {*por_ready}] -to [get_regs {*u_*reset/ready_meta}]

# Buffer publication is a bundled-data request/ack mailbox. held_index remains
# unchanged until frame-boundary capture and acknowledgement return to source.
set_max_delay -from [get_regs {*u_frame_publish/held_index[*]}] -to [get_regs {*u_frame_publish/pending_index[*]}] 25 -datapath_only
set_false_path -to [get_regs {*u_frame_publish/request_meta}]
set_false_path -to [get_regs {*u_frame_publish/ack_meta}]
