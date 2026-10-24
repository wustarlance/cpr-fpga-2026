#=============================================================================
# flow.tcl —— 音频链 TD 综合 / 布局 / 布线 / 时序（命令行，可重跑）
#-----------------------------------------------------------------------------
# 运行方式（CWD 必须是 workbuddy_change 目录 —— 与 .al 内相对路径的基准一致，
# 也正好等于 TD GUI 双击打开 .al 时的 CWD）：
#     cd D:/ANLU/code/cpr-fpga-2026/project/workbuddy_change
#     td_commands_prompt.exe scripts/flow.tcl
#
# ⚠️ 为什么不用 TD 自带的 audio_tmg_Runs/syn_1/DefaultFlow.tcl：
#    那条路要求 .prj 里的相对路径能被正确解析，实测在命令行下
#    "Successfully analyzed 0 source files"，根因是 TD 命令行对相对路径的
#    解析基准是进程 CWD（不是 .al 的 <Project Path>），而 run 快照又比 .al
#    多一层目录，很容易全落空。这里直接在 CWD=project 下打开
#    audio_tmg.al（其中路径相对 workbuddy_change 书写），
#    已实测 analyze 13 个文件 + elaborate 通过。
#
# 阶段可用环境变量 AT_STAGE 控制：gate(默认) / place / route
#=============================================================================
set stage "gate"
if {[info exists ::env(AT_STAGE)]} { set stage $::env(AT_STAGE) }

set wbc       [pwd]
set out       "$wbc/build"
file mkdir $out

set top       "audio_tmg_top"
set sdc       "constraints/audio_tmg.sdc"

proc banner {t} { puts "\n########## $t ##########" }

proc checkpoint {name} {
    global out
    if {[catch {export_db "$out/$name.db"} m]} { puts "  export_db $name FAIL: $m" } \
    else { puts "  export_db $name OK" }
}

banner "0. device + project"
import_device eagle_s20.db -package EG4S20BG256
open_project "audio_tmg.al"

banner "1. elaborate"
elaborate -top $top

banner "2. read sdc"
if {[catch {read_sdc $sdc} m]} { puts "  SDC FAIL: $m" } else { puts "  SDC OK" }

banner "3. optimize_rtl"
commit_param -step rtl
optimize_rtl
report_area -file "$out/rtl_area.rpt"
checkpoint audio_tmg_rtl

banner "4. optimize_gate"
commit_param -step gate
optimize_gate -packarea "$out/gate.area"
legalize_phy_inst
update_timing
report_area -file "$out/gate_area.rpt"
report_timing_status  -file "$out/gate_timing_status.rpt"
report_timing_summary -file "$out/gate_timing_summary.rpt"
checkpoint audio_tmg_gate

if {$stage eq "gate"} {
    puts "\nDONE (stage=gate)"
    exit
}

banner "5. place"
commit_param -step place
if {[catch {place} m]} {
    puts "  PLACE FAIL: $m"
    puts "\nDONE (stage=gate, place failed)"
    exit
}
update_timing -mode manhattan
report_area -io_info -file "$out/place_area.rpt"
report_timing_summary -file "$out/place_timing_summary.rpt"
report_clock_utilization -file "$out/place_clock_util.txt"
checkpoint audio_tmg_place

if {$stage eq "place"} {
    puts "\nDONE (stage=place)"
    exit
}

banner "6. route"
commit_param -step route
if {[catch {route} m]} {
    puts "  ROUTE FAIL: $m"
    puts "\nDONE (stage=place, route failed)"
    exit
}
report_area -io_info -file "$out/route_area.rpt"
update_timing -mode final
report_timing_status  -file "$out/route_timing_status.rpt"
report_timing_summary -file "$out/route_timing_summary.rpt"
report_timing_exception -file "$out/route_exception.rpt"
report_clock_utilization -file "$out/route_clock_util.txt"
checkpoint audio_tmg_route

banner "DONE (stage=route)"
exit
