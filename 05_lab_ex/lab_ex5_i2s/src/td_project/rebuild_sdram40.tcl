# Standard TD project runs, matching GUI syn_1 -> phy_1.
# Run: td rebuild_sdram40.tcl (CLI only; exit closes the TD process).
cd [file dirname [file normalize [info script]]]
file mkdir build

proc rebuild_example5 {} {
    import_device eagle_s20.db -package EG4S20BG256
    open_project HDMI1.4b_Transmitter_v1.0.al
    reset_runs syn_1
    launch_runs {syn_1 phy_1} -jobs 2
    wait_run syn_1 -quiet
    wait_run phy_1 -quiet
    open_run phy_1
    update_timing -mode final
    report_timing_status -file build/gui_timing_status.rpt
    report_timing_summary -file build/gui_timing_summary.rpt
    check_timing -verbose -file build/gui_timing_check.rpt

    set stream [open build/gui_timing_status.rpt r]
    set timing [read $stream]
    close $stream
    if {![regexp {SWNS:\s*([-+0-9.]+)ns,\s*STNS:\s*([-+0-9.]+)ns} $timing -> swns stns] ||
        ![regexp {HWNS:\s*([-+0-9.]+)ns,\s*HTNS:\s*([-+0-9.]+)ns} $timing -> hwns htns]} {
        error "Cannot parse standard-run timing status"
    }
    if {$swns < 0 || $hwns < 0 || $stns < 0 || $htns < 0} {
        error "Standard-run timing failed: setup=$swns ns, hold=$hwns ns"
    }
    save_best_bits
    file copy -force HDMI1.4b_Transmitter_v1.0_Runs/phy_1/HDMI1.4b_Transmitter_v1.0.bit build/lab_ex5_sdram40.bit
    puts "STANDARD_RUN_PASS: setup=$swns ns, hold=$hwns ns"
    close_run
    close_project
}

if {[catch {rebuild_example5} message]} {
    puts stderr "STANDARD_RUN_FAIL: $message"
    exit 1
}
exit
