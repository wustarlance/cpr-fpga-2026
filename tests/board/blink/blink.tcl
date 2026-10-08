# ============================================================================
# blink.tcl —— 全命令行构建脚本（不依赖 TD GUI）
#
# 用法（在本目录下）：
#     ../../../../.tools/td blink.tcl
#
# 产物：blink.bit（约 614 KB）
#
# 为什么用脚本而不是 GUI：
#   1. 可重复 —— 每次构建的命令完全一致，不会因为手点错选项而结果不同
#   2. 可版本控制 —— 脚本进 git，GUI 里的设置不会
#   3. 便于排查 —— 每一步失败都立刻停下来报告，日志在 td_*.log
#
# 流程（安路 HDL2BIT 全流程）：
#   import_device → read_verilog → read_adc → optimize_rtl
#   → optimize_gate → place → route → bitgen
# ============================================================================

proc step {desc cmd} {
    puts ">>> $desc"
    if {[catch {uplevel 1 $cmd} res]} {
        puts "    [string toupper $desc] FAILED: $res"
        return 1
    }
    puts "    ok"
    return 0
}

# ---- 指定器件：EG4S20BG256 ----
step "import_device" {import_device eagle_s20.db -package EG4S20BG256}

# ---- 读设计（read_verilog 内部已含 analyze + elaborate，不要再单独调 elaborate）----
step "read_verilog" {read_verilog -file blink.v -top blink}

# ---- 读引脚约束 ----
step "read_adc" {read_adc blink.adc}

# ---- 综合与布局布线 ----
step "optimize_rtl" {optimize_rtl}
step "optimize_gate" {optimize_gate -packarea blink_gate.area}
step "place" {place}
step "route" {route}

# ---- 生成位流 ----
step "bitgen" {bitgen -bit blink.bit}

puts "=== BLINK BITGEN DONE ==="
exit
