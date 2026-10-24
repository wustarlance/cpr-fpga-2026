# Persistent terminal flags and physical switch inputs.
# No clock groups, no SDRAM multicycle paths, no FIFO exceptions.
# Each DIP input drives only dip_meta, never downstream combinational logic.
# A timing path from this port ends at that first register. Leave the second
# synchronizer stage and all register-to-register paths timed. Naming the port
# also survives TD packing the first register into an input cell.
set_false_path -from [get_ports {dip_sw[*]}]
set_false_path -to [get_regs {*pass_meta *fail_meta}]
