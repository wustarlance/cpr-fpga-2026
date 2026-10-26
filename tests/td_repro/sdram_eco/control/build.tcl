cd [file dirname [file normalize [info script]]]
set label $::env(CPR_PROBE_LABEL)
if {$label ni {unconstrained fixed}} {error "Unknown diagnostic variant"}
file mkdir $label
if {[catch {
 import_device eagle_s20.db -package EG4S20BG256
 read_hdl -file probe.v -top sdram_location_probe
 read_adc pin.adc
 read_sdc timing.sdc
 optimize_rtl
 optimize_gate
 legalize_phy_inst
 if {$label eq "fixed"} {read_adc macro.adc}
 read_sdc timing.sdc
 set_param place opt_timing high
 report_area -file $label/gate_area.rpt
 place
 route
 update_timing -mode final
 report_cells [get_cells {sdram}]
 report_route_status -drc
 check_timing -verbose -file $label/timing_check.rpt
 report_timing_status -file $label/timing_status.rpt
 write_pnl $label/routed.pnl -clk -v
 puts "CPR_MINIMAL_SDRAM_DONE $label"
} problem]} {puts stderr "CPR_MINIMAL_SDRAM_FAILED $label: $problem";exit 1}
exit
