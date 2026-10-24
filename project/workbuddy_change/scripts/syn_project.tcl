#=============================================================
# syn_project.tcl —— 用本机 TD 6.2.1 对总工程做综合检验（optimize_rtl）
# 运行（CWD 必须是 project 目录）：
#   cd D:/ANLU/code/cpr-fpga-2026/project
#   "D:/ANLU/TD_6.2.1/bin/td_commands_prompt.exe" workbuddy_change/scripts/syn_project.tcl
# 目的：optimize_rtl 会真正展开 enc.v 解密后的 RTL 并综合成网表，
#       是"加密核能被正确解析"的最强编译级验证。
#=============================================================
proc banner {t} { puts "\n########## $t ##########" }

set out "[pwd]/workbuddy_change/build_syn"
file mkdir $out

banner "总工程 optimize_rtl 综合检验"
puts "CWD = [pwd]"

import_device eagle_s20.db -package EG4S20BG256
puts "  import_device OK"

open_project "project.al"
puts "  open_project OK"

if {[catch {elaborate -top top} m]} {
    puts "\n########## ELABORATE FAILED ##########"
    puts $m
    puts "\n############ RESULT=ELAB_FAIL ############"
} else {
    puts "  elaborate OK"
    if {[catch {commit_param -step rtl} m]} {
        puts "\n########## COMMIT_PARAM FAILED ##########"; puts $m
        puts "\n############ RESULT=PARAM_FAIL ############"
    } elseif {[catch {optimize_rtl} m]} {
        puts "\n########## OPTIMIZE_RTL FAILED ##########"
        puts $m
        puts "\n############ RESULT=RTL_FAIL ############"
    } else {
        catch {report_area -file "$out/rtl_area.rpt"}
        puts "\n########## OPTIMIZE_RTL OK ##########"
        if {[catch {exec cat "$out/rtl_area.rpt"} rpt]} { set rpt "(area report not readable)" }
        puts $rpt
        puts "\n############ RESULT=PASS ############"
    }
}
