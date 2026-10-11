# Run with: cd 05_lab_ex/lab_ex5_i2s/src/td_project && td build_sdram40.tcl
# Keep the GUI runs and their previous best_result separate from this build.
cd [file dirname [file normalize [info script]]]
file mkdir build

proc build_project {} {
    import_device eagle_s20.db -package EG4S20BG256
    open_project HDMI1.4b_Transmitter_v1.0.al -single_run
    load_run_param -run syn_1
    elaborate -top top
    read_adc ../user_source/constraints_source/pin.adc
    read_sdc ../user_source/constraints_source/timing.sdc
    read_sdc -ip rfifo_32_32_512 ../user_source/hdl_source/IP/afifo_32_16_256.tcl
    read_sdc -ip wfifo_32_32_512 ../user_source/hdl_source/IP/afifo_16_32_256.tcl

    commit_param -step rtl
    optimize_rtl
    commit_param -step gate
    optimize_gate -packarea build/project_gate.area
    legalize_phy_inst
    commit_param -step place
    place
    commit_param -step route
    route
    update_timing -mode final
    # Check the physical PLL outputs, rather than trusting comments or .ipc alone.
    foreach {clock expected_period} {
        sd_card_clk 10.0
        ext_mem_clk 25.0
        ext_mem_clk_sft 25.0
        video_clk 40.0
        hdmi_5x_clk 8.0
    } {
        set clocks [get_clocks $clock]
        if {$clocks eq ""} { error "Required clock missing: $clock" }
        set period [get_property -max PERIOD $clocks]
        if {abs($period - $expected_period) > 0.001} {
            error "Clock $clock has period $period ns; expected $expected_period ns"
        }
    }

    report_timing_status -file build/timing_status.rpt
    report_timing_summary -file build/timing_summary.rpt
    check_timing -verbose -file build/timing_check.rpt
    report_area -file build/final_area.rpt

    set report [open build/timing_status.rpt r]
    set timing [read $report]
    close $report
    if {![regexp {SWNS:\s*([-+0-9.]+)ns,\s*STNS:\s*([-+0-9.]+)ns} $timing -> swns stns] ||
        ![regexp {HWNS:\s*([-+0-9.]+)ns,\s*HTNS:\s*([-+0-9.]+)ns} $timing -> hwns htns]} {
        error "Cannot parse routed timing status; inspect build/timing_status.rpt"
    }
    if {$swns < 0 || $hwns < 0 || $stns < 0 || $htns < 0} {
        error "Timing failed: setup WNS=$swns ns, hold WNS=$hwns ns"
    }

    commit_param -step bitgen
    bitgen -bit build/lab_ex5_sdram40.bit
    puts "BUILD_PASS: setup WNS=$swns ns, hold WNS=$hwns ns; build/lab_ex5_sdram40.bit"
}

if {[catch {build_project} message]} {
    puts stderr "BUILD_FAIL: $message"
    exit 1
}
exit
