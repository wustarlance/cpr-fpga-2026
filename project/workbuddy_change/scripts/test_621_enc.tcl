#=============================================================
# test_621_enc.tcl —— 用 TD 6.2.1 验证 HDMI 加密核能否解析
# 运行：cd workbuddy_change
#       "D:/ANLU/TD_6.2.1/bin/td_commands_prompt.exe" scripts/test_621_enc.tcl
# 目的：audio_board.al 含 hdmi_1_4b_transmitter_core_wrapper.enc.v，
#       若能 elaborate 通过，说明 6.2.1 可解 IEEE-1735 加密核。
#=============================================================
proc banner {t} { puts "\n########## $t ##########" }

banner "TD 6.2.1 加密核解析验证"
puts "CWD = [pwd]"

import_device eagle_s20.db -package EG4S20BG256
puts "  import_device OK"

open_project "audio_board.al"
puts "  open_project OK"

if {[catch {elaborate -top audio_board_top} err]} {
    puts "\n########## ELABORATE FAILED ##########"
    puts $err
    puts "\n############################ RESULT=FAIL ############################"
} else {
    puts "\n########## ELABORATE OK ##########"
    puts "\n############################ RESULT=PASS ############################"
}
