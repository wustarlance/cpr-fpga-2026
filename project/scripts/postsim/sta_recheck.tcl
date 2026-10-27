# TD 6.2.1: td_commands_prompt.exe sta_recheck.tcl    （配合 CPR_TOP 环境变量）
#
# 只做时序复核：从已布线的 route.db 重新做一次 update_timing -mode final，
# 输出状态汇总 + 最差路径明细，不写网表、不动仿真产物。
#   build/<top>/simulation/timing_recheck.rpt   最差路径明细（setup + hold）
#
# 说明：build.tcl 里 export_db 排在 update_timing 之前，所以 route.db 里存的
# 是"布线刚结束、还没做 final 提取"的延时。重新导入后做一次 final 更新，
# 得到的 SWNS/HWNS 比构建日志里那一次略保守（top: 0.188→0.114），
# 报告里以后者为准。
set cpr_top top
if {[info exists ::env(CPR_TOP)]} { set cpr_top $::env(CPR_TOP) }
set cpr_dir [file join build $cpr_top simulation]
file mkdir $cpr_dir
set cpr_out [file normalize [file join $cpr_dir timing_recheck.rpt]]

if {[catch {
    import_device eagle_s20.db -package EG4S20BG256
    open_project project.al -single_run
    import_db [file join build $cpr_top route.db]
    update_timing -mode final
    report_timing_status -file [file join $cpr_dir sta_recheck.rpt]
    report_timing_summary -file $cpr_out
    puts "STA_RECHECK_PASS $cpr_top"
} cpr_error]} {
    puts stderr "STA_RECHECK_FAIL $cpr_top: $cpr_error"
    exit 1
}
exit
