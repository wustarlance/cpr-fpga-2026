# 按压盒标定探针：独立工程 probe.al + 独立引脚/时序约束，不碰正式工程。
#   td_commands_prompt.exe build_probe.tcl
# 产出：project/build/probe/top_adc_probe.bit
cd [file dirname [file normalize [info script]]]
set cpr_reports [file join build probe]
file mkdir $cpr_reports
if {[catch {
    import_device eagle_s20.db -package EG4S20BG256
    open_project probe.al -single_run
    load_run_param -run syn_1
    elaborate -top top_adc_probe
    read_adc probe/pin.adc
    read_sdc probe/probe.sdc
    # ADC 采样信箱的跨域约束复用正式工程那份（通配路径在探针里同样匹配）
    read_sdc constraints/adc_mailbox.sdc
    read_sdc probe/probe_cdc.sdc
    commit_param -step rtl
    optimize_rtl
    read_sdc probe/probe.sdc
    report_area -file $cpr_reports/rtl_area.rpt
    commit_param -step gate
    optimize_gate -packarea $cpr_reports/gate.area
    legalize_phy_inst
    read_sdc probe/probe.sdc
    report_area -file $cpr_reports/gate_area.rpt
    export_db $cpr_reports/gate.db
    report_qor -step gate -file $cpr_reports/gate.qor
    set_param place opt_timing high
    commit_param -step place
    place
    report_qor -step place -file $cpr_reports/place.qor
    commit_param -step route
    route
    export_db $cpr_reports/route.db
    report_qor -step route -file $cpr_reports/route.qor
    update_timing -mode final
    report_timing_status -file $cpr_reports/timing_status.rpt
    report_timing_summary -file $cpr_reports/timing_summary.rpt
    report_clock_summary -file $cpr_reports/clock_summary.rpt
    # 时序门：和正式 flow 一样，直接解析 timing_status.rpt，不依赖查询命令
    set f [open $cpr_reports/timing_status.rpt r]
    set timing [read $f]; close $f
    if {![regexp {SWNS:\s*([-+0-9.]+)ns,\s*STNS:\s*([-+0-9.]+)ns} $timing -> sw st] ||
        ![regexp {HWNS:\s*([-+0-9.]+)ns,\s*HTNS:\s*([-+0-9.]+)ns} $timing -> hw ht]} {
        error "Cannot parse probe timing report"
    }
    puts "PROBE_TIMING setup=$sw hold=$hw"
    if {$sw<0 || $st<0 || $hw<0 || $ht<0} { error "Probe timing failed: setup=$sw hold=$hw" }
    commit_param -step bitgen
    bitgen -bit $cpr_reports/top_adc_probe.bit
} cpr_err]} {
    puts "CPR_BUILD_FAIL top_adc_probe: $cpr_err"
    exit 1
}
puts "CPR_BUILD_PASS top_adc_probe"
