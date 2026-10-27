# TD 6.2.1: td_commands_prompt.exe export.tcl    （配合 CPR_TOP 环境变量）
#
# 从已布线的 build/<top>/route.db 导出后仿真所需的三样东西，不重跑 P&R：
#   build/<top>/simulation/<top>_sim.v  门级网表（write_verilog 结果）
#   build/<top>/simulation/<top>.sdf    RC 反标延时（write_sdf 结果）
#   build/<top>/simulation/sta_recheck.rpt 重新用 -mode final 算一遍的 SWNS/HWNS
#
# 注意 write_verilog 的 -sdf 参数是"把 $sdf_annotate 写进网表"，值为绝对路径。
# 用相对路径时 vsim 的工作目录不同就会 ENOENT，所以这里给绝对路径。
set cpr_top top
if {[info exists ::env(CPR_TOP)]} { set cpr_top $::env(CPR_TOP) }
set cpr_dir [file join build $cpr_top simulation]
file mkdir $cpr_dir
set cpr_sdf [file normalize [file join $cpr_dir $cpr_top.sdf]]
set cpr_v   [file normalize [file join $cpr_dir ${cpr_top}_sim.v]]
set cpr_rpt [file normalize [file join $cpr_dir sta_recheck.rpt]]

if {[catch {
    import_device eagle_s20.db -package EG4S20BG256
    open_project project.al -single_run
    import_db [file join build $cpr_top route.db]
    update_timing -mode final
    report_timing_status -file $cpr_rpt
    write_sdf -file $cpr_sdf
    write_verilog -sdf [string map {\\ /} $cpr_sdf] $cpr_v
    puts "POSTSIM_EXPORT_PASS $cpr_top"
} cpr_error]} {
    puts stderr "POSTSIM_EXPORT_FAIL $cpr_top: $cpr_error"
    exit 1
}
exit
