# Rebuild standard GUI runs for the default board-button top. CLI only.
cd [file dirname [file normalize [info script]]]
file mkdir build/top
proc rebuild {} {
    import_device eagle_s20.db -package EG4S20BG256
    open_project project.al
    reset_runs syn_1
    launch_runs {syn_1 phy_1} -jobs 2
    wait_run syn_1 -quiet
    wait_run phy_1 -quiet
    open_run phy_1
    update_timing -mode final
    report_timing_status -file build/top/gui_timing_status.rpt
    report_timing_summary -file build/top/gui_timing_summary.rpt
    check_timing -verbose -file build/top/gui_timing_check.rpt
    set f [open build/top/gui_timing_status.rpt r]
    set timing [read $f];close $f
    if {![regexp {SWNS:\s*([-+0-9.]+)ns,\s*STNS:\s*([-+0-9.]+)ns} $timing -> sw st] ||
        ![regexp {HWNS:\s*([-+0-9.]+)ns,\s*HTNS:\s*([-+0-9.]+)ns} $timing -> hw ht]} { error "Cannot parse GUI timing" }
    if {$sw<0 || $st<0 || $hw<0 || $ht<0} { error "GUI timing failed: $sw / $hw" }
    save_best_bits
    puts "CPR_GUI_PASS setup=$sw hold=$hw"
    close_run
    close_project
}
if {[catch {rebuild} message]} { puts stderr "CPR_GUI_FAIL: $message";exit 1 }
exit
