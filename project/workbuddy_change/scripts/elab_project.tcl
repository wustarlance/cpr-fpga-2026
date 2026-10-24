#=============================================================
# elab_project.tcl —— 总工程 project.al 的 elaborate 基线验证
# 运行（CWD 必须是 project 目录，与 project.al 内相对路径基准一致）：
#   cd D:/ANLU/code/cpr-fpga-2026/project
#   "D:/ANLU/TD_6.2.1/bin/td_commands_prompt.exe" workbuddy_change/scripts/elab_project.tcl
#=============================================================
proc banner {t} { puts "\n########## $t ##########" }

set top "top"
if {[info exists ::env(ELAB_TOP)]} { set top $::env(ELAB_TOP) }

banner "总工程 elaborate 基线"
puts "CWD = [pwd]"
puts "TOP = $top"

import_device eagle_s20.db -package EG4S20BG256
puts "  import_device OK"

open_project "project.al"
puts "  open_project OK"

if {[catch {elaborate -top $top} err]} {
    puts "\n########## ELABORATE FAILED ##########"
    puts $err
    puts "\n############ RESULT=FAIL ############"
} else {
    puts "\n########## ELABORATE OK ##########"
    puts "\n############ RESULT=PASS ############"
}
