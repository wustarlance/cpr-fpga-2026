#=============================================================================
# build_project.tcl —— 总工程（project.al / 顶层 top）综合 → 布局 → 布线 → 位流
#-----------------------------------------------------------------------------
# 运行方式（CWD 必须是 project 目录，project.al 内相对路径以 CWD 为基准）：
#     cd D:/ANLU/code/cpr-fpga-2026/project
#     set BP_STAGE=gate    && td_commands_prompt.exe scripts/build_project.tcl
#     set BP_STAGE=place   && ...
#     set BP_STAGE=route   && ...
#     set BP_STAGE=bit     && ...
#   （bash 下用 export BP_STAGE=xxx）
#
# 阶段说明：
#   gate  : elaborate + 读 SDC + optimize_rtl/gate，出面积与时序报告（最快，先看资源）
#   place : 追加布局
#   route : 追加布线 + 最终时序
#   bit   : 追加位流生成 → build_project/top.bit
#=============================================================================
set stage "gate"
if {[info exists ::env(BP_STAGE)]} { set stage $::env(BP_STAGE) }

set proj [pwd]
set out  "$proj/build_project"
file mkdir $out

set top "top"

proc banner {t} { puts "\n########## $t ##########" }

proc checkpoint {name} {
    global out
    if {[catch {export_db "$out/$name.db"} m]} {
        puts "  export_db $name FAIL: $m"
    } else {
        puts "  export_db $name OK"
    }
}

puts "PROJECT = $proj"
puts "STAGE   = $stage"

banner "0. device + project"
import_device eagle_s20.db -package EG4S20BG256
open_project "project.al"

banner "1. elaborate"
if {[catch {elaborate -top $top} m]} {
    puts "  ELABORATE FAIL: $m"
    exit
}
puts "  elaborate OK"

banner "2. read adc + sdc"
# pin.adc 必须显式 read_adc 才会生效：open_project 不带 -single_run 时
# 只建立层次，不自动套用 .al 里登记的约束。漏掉会导致所有 IO 自动摆放，
# 最后 bitgen 报 BIT-8123（有未约束 IO）直接拒绝生成位流。
if {[catch {read_adc constraints/pin.adc} m]} {
    puts "  ADC FAIL: $m"
} else {
    puts "  ADC constraints/pin.adc OK"
}
foreach s {constraints/timing.sdc constraints/reset_publish.sdc constraints/page_status.sdc constraints/project_cdc.sdc} {
    if {[catch {read_sdc $s} m]} {
        puts "  SDC $s FAIL: $m"
    } else {
        puts "  SDC $s OK"
    }
}

banner "3. optimize_rtl"
commit_param -step rtl
optimize_rtl
report_area -file "$out/rtl_area.rpt"
checkpoint project_rtl

banner "4. optimize_gate"
commit_param -step gate
optimize_gate -packarea "$out/gate.area"
legalize_phy_inst
update_timing
report_area           -file "$out/gate_area.rpt"
report_timing_status  -file "$out/gate_timing_status.rpt"
report_timing_summary -file "$out/gate_timing_summary.rpt"
checkpoint project_gate

if {$stage eq "gate"} {
    puts "\nDONE (stage=gate)"
    exit
}

banner "5. place"
commit_param -step place
if {[catch {place} m]} {
    puts "  PLACE FAIL: $m"
    exit
}
update_timing -mode manhattan
report_area -io_info   -file "$out/place_area.rpt"
report_timing_summary  -file "$out/place_timing_summary.rpt"
report_clock_utilization -file "$out/place_clock_util.txt"
checkpoint project_place

if {$stage eq "place"} {
    puts "\nDONE (stage=place)"
    exit
}

banner "6. route"
commit_param -step route
if {[catch {route} m]} {
    puts "  ROUTE FAIL: $m"
    exit
}
report_area -io_info   -file "$out/route_area.rpt"
update_timing -mode final
report_timing_status   -file "$out/route_timing_status.rpt"
report_timing_summary  -file "$out/route_timing_summary.rpt"
report_timing_exception -file "$out/route_exception.rpt"
report_clock_utilization -file "$out/route_clock_util.txt"
checkpoint project_route

if {$stage eq "route"} {
    puts "\nDONE (stage=route)"
    exit
}

banner "7. bitgen"
commit_param -step bitgen
if {[catch {bitgen -bit "$out/$top.bit"} m]} {
    puts "  BITGEN FAIL: $m"
    exit
}
puts "  bitgen OK -> $out/$top.bit"

banner "DONE (stage=bit)"
exit
