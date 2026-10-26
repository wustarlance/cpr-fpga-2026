# 综合一个变体：CPR_VAR 指定顶层模块，CPR_AL 指定工程文件（默认 romtest.al）
set top $::env(CPR_VAR)
if {[info exists ::env(CPR_AL)]} { set al $::env(CPR_AL) } else { set al romtest.al }
import_device eagle_s20.db -package EG4S20BG256
open_project $al -single_run
load_run_param -run syn_1
elaborate -top $top
optimize_rtl
commit_param -step gate
optimize_gate -packarea ./gate.area
report_qor -step gate -file ./qor_$top.qor
puts "SYN_DONE $top"
exit
