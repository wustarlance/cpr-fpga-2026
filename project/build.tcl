# TD 6.2.1: td_commands_prompt.exe build.tcl
# CPR_TOP=top (board demo, default) or top_adc (uncalibrated sensor).
# Synthesis only; no bitstream generation or programming.
cd [file dirname [file normalize [info script]]]
set cpr_top top
if {[info exists ::env(CPR_TOP)]} { set cpr_top $::env(CPR_TOP) }
if {$cpr_top ni {top top_adc}} {
    puts stderr "Unsupported CPR_TOP: $cpr_top"
    exit 1
}
set cpr_reports [file join build $cpr_top]
file mkdir $cpr_reports
if {[catch {
    import_device eagle_s20.db -package EG4S20BG256
    open_project project.al -single_run
    load_run_param -run syn_1
    elaborate -top $cpr_top
    read_adc constraints/pin.adc
    read_sdc constraints/timing.sdc
    if {$cpr_top eq "top_adc"} {
        read_sdc constraints/adc_mailbox.sdc
    }
    read_sdc -ip rfifo_32_32_512 ../05_lab_ex/lab_ex5_i2s/src/user_source/hdl_source/IP/afifo_32_16_256.tcl
    read_sdc -ip wfifo_32_32_512 ../05_lab_ex/lab_ex5_i2s/src/user_source/hdl_source/IP/afifo_16_32_256.tcl
    commit_param -step rtl
    optimize_rtl
    # get_regs resolves register objects after RTL optimization, rather than
    # against the HDL-only design immediately after elaborate.
    if {$cpr_top eq "top_adc"} {
        set cpr_src [get_regs {*u_mailbox/src_hold[*]}]
        set cpr_dst [get_regs {*u_mailbox/dst_data[*]}]
        if {[llength $cpr_src] != 12 || [llength $cpr_dst] != 12} {
            error "ADC mailbox must bind 12 source and 12 capture registers"
        }
    }
    report_area -file $cpr_reports/rtl_area.rpt
    commit_param -step gate
    optimize_gate -packarea $cpr_reports/gate.area
    legalize_phy_inst
    report_area -file $cpr_reports/gate_area.rpt
} cpr_error]} {
    puts stderr "CPR_SYNTHESIS_FAIL $cpr_top: $cpr_error"
    exit 1
}
puts "CPR_SYNTHESIS_PASS $cpr_top"
exit
