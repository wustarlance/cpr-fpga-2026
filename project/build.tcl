# TD 6.2.1: td_commands_prompt.exe build.tcl
# CPR_TOP=top (board demo, default) or top_adc (uncalibrated sensor).
# Full build by default. CPR_STAGE=synth selects synthesis only; never programs hardware.
cd [file dirname [file normalize [info script]]]
set cpr_top top
if {[info exists ::env(CPR_TOP)]} { set cpr_top $::env(CPR_TOP) }
if {$cpr_top ni {top top_adc}} {
    puts stderr "Unsupported CPR_TOP: $cpr_top"
    exit 1
}
set cpr_stage full
if {[info exists ::env(CPR_STAGE)]} { set cpr_stage $::env(CPR_STAGE) }
if {$cpr_stage ni {synth full}} { puts stderr "Invalid CPR_STAGE: $cpr_stage"; exit 1 }
set cpr_reports [file join build $cpr_top]
file mkdir $cpr_reports
if {[catch {
    import_device eagle_s20.db -package EG4S20BG256
    open_project project.al -single_run
    load_run_param -run syn_1
    elaborate -top $cpr_top
    read_adc constraints/pin.adc
    read_sdc constraints/timing.sdc
    read_sdc constraints/reset_publish.sdc
    if {$cpr_top eq "top_adc"} {
        read_sdc constraints/adc_mailbox.sdc
    }
    read_sdc -ip rfifo_32_32_512 ../05_lab_ex/lab_ex5_i2s/src/user_source/hdl_source/IP/afifo_32_16_256.tcl
    read_sdc -ip wfifo_32_32_512 ../05_lab_ex/lab_ex5_i2s/src/user_source/hdl_source/IP/afifo_16_32_256.tcl
    commit_param -step rtl
    optimize_rtl
    read_sdc constraints/reset_publish.sdc
    set cpr_reset_pins [get_regs {*u_*reset/ready_meta}]
    if {[llength $cpr_reset_pins] != 4} { error "Expected four readiness synchronizer first stages" }
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
    if {$cpr_stage eq "full"} {
        commit_param -step place
        place
        commit_param -step route
        route
        update_timing -mode final
        report_timing_status -file $cpr_reports/timing_status.rpt
        report_timing_summary -file $cpr_reports/timing_summary.rpt
        check_timing -verbose -file $cpr_reports/timing_check.rpt

        foreach {clock period} {sd_card_clk 10 ext_mem_clk 25 ext_mem_clk_sft 25 video_clk 40 hdmi_5x_clk 8} {
            set actual [get_property -max PERIOD [get_clocks $clock]]
            if {abs($actual-$period)>0.001} { error "Unexpected period for $clock: $actual" }
        }
        set f [open $cpr_reports/timing_status.rpt r]
        set timing [read $f]; close $f
        if {![regexp {SWNS:\s*([-+0-9.]+)ns,\s*STNS:\s*([-+0-9.]+)ns} $timing -> sw st] ||
            ![regexp {HWNS:\s*([-+0-9.]+)ns,\s*HTNS:\s*([-+0-9.]+)ns} $timing -> hw ht]} {
            error "Cannot parse routed timing report"
        }
        if {$sw<0 || $st<0 || $hw<0 || $ht<0} { error "Timing failed: setup=$sw hold=$hw" }
        commit_param -step bitgen
        bitgen -bit $cpr_reports/$cpr_top.bit
        puts "CPR_BUILD_PASS $cpr_top setup=$sw hold=$hw"
    }

} cpr_error]} {
    puts stderr "CPR_BUILD_FAIL $cpr_top: $cpr_error"
    exit 1
}
if {$cpr_stage eq "synth"} { puts "CPR_SYNTHESIS_PASS $cpr_top" }
exit
