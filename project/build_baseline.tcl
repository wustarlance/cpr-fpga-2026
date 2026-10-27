# TD 6.2.1: td_commands_prompt.exe build_baseline.tcl
# CPR_TOP=top (board demo, default) or top_adc (uncalibrated sensor).
# Full build by default. CPR_STAGE=synth selects synthesis only; never programs hardware.
#
# =============================================================================
# 基线（已知上板可用）构建脚本 —— 2026-10-26 留存
# -----------------------------------------------------------------------------
# 这份就是 `build.tcl` 在**今天那批时序实验参数之前**的原样内容：
# `place opt_timing high` 一条，没有 `infer_fsm one_hot`、没有 gate 的
# `map_mode balance_explore`、没有 place/route 的 post_opt/split_data_from_clock。
#
# 为什么单独留一份：今天下午为了把 sd_card_clk（100 MHz）上那两条 BMP 读取锥
# 的 setup 从负值拉正，往 build.tcl 里加了一批 TimingHigh + aggressive_opt 的
# 参数，构建日志显示两个顶层都 PASS（top setup +0.210 / hold +0.004），但
# **上板后 HDMI 全黑、无声音**（数码管正常，说明芯片起来、复位已放、时钟在跑）。
# 症状从 18:29 那份（同一套 RTL、只有 P&R 参数不同）开始出现，14:29 那份
# 旧的可用，所以嫌疑集中在这批参数上。
#
# 因此 build.tcl 已回退成这份基线内容；本文件是它的**带说明副本**，用途是：
#   1) 出"能上板"的位流（默认就用它，或直接用已回退的 build.tcl）；
#   2) 拿它和 build_fast.tcl（带实验参数）逐项差分，定位到底是哪一条参数
#      把功能改坏了 —— 两者除了参数块以外流程完全一致。
#
# 用法与 build.tcl 完全一样（脚本用 [info script] 定位自己，改名不影响）：
#   CPR_TOP=top     D:\ANLU\TD_6.2.1\bin\td_commands_prompt.exe build_baseline.tcl
#   CPR_TOP=top_adc D:\ANLU\TD_6.2.1\bin\td_commands_prompt.exe build_baseline.tcl
#
# 已知数字（基线参数，2026-10-26）：top setup +0.123~+0.128 / hold +0.004，
# top_adc setup +0.196 / hold +0.003 —— 正余量，但比实验参数低约 60~80 ps。
# =============================================================================
cd [file dirname [file normalize [info script]]]
set cpr_top top
if {[info exists ::env(CPR_TOP)]} { set cpr_top $::env(CPR_TOP) }
if {$cpr_top ni {top top_adc}} {
    puts stderr "Unsupported CPR_TOP: $cpr_top"
    exit 1
}
set cpr_stage full
if {[info exists ::env(CPR_STAGE)]} { set cpr_stage $::env(CPR_STAGE) }
if {$cpr_stage ni {synth full}} { puts stderr "Invalid CPR_STAGE: $cpr_stage"; exit 1 }
set cpr_reports [file join build $cpr_top]
file mkdir $cpr_reports
if {[catch {
    import_device eagle_s20.db -package EG4S20BG256
    open_project project.al -single_run
    load_run_param -run syn_1
    elaborate -top $cpr_top
    read_adc constraints/pin.adc
    read_sdc constraints/timing.sdc
    read_sdc constraints/reset_publish.sdc
    if {$cpr_top eq "top_adc"} {
        read_sdc constraints/adc_mailbox.sdc
    }
    read_sdc -ip rfifo_32_32_512 ../05_lab_ex/lab_ex5_i2s/src/user_source/hdl_source/IP/afifo_32_16_256.tcl
    read_sdc -ip wfifo_32_32_512 ../05_lab_ex/lab_ex5_i2s/src/user_source/hdl_source/IP/afifo_16_32_256.tcl
    commit_param -step rtl
    optimize_rtl
    read_sdc constraints/reset_publish.sdc
    set cpr_reset_pins [get_regs {*u_*reset/ready_meta}]
    if {$cpr_top eq "top_adc"} {
        if {[llength $cpr_reset_pins] != 4} {
            error "Expected four readiness synchronizer first stages for top_adc"
        }
    } elseif {[llength $cpr_reset_pins] != 3 && [llength $cpr_reset_pins] != 4} {
        error "Expected three or four readiness synchronizer first stages for top"
    }
    # get_regs resolves register objects after RTL optimization, rather than
    # against the HDL-only design immediately after elaborate.
    if {$cpr_top eq "top_adc"} {
        set cpr_src [get_regs {*u_mailbox/src_hold[*]}]
        set cpr_dst [get_regs {*u_mailbox/dst_data[*]}]
        set cpr_hold_names {}; set cpr_capture_names {}
        foreach cpr_reg $cpr_src { lappend cpr_hold_names [format {{%s}} $cpr_reg] }
        foreach cpr_reg $cpr_dst { lappend cpr_capture_names [format {{%s}} $cpr_reg] }
        puts "CPR_MAILBOX_REGS hold=[join $cpr_hold_names { }] capture=[join $cpr_capture_names { }]"
        if {[llength $cpr_src] != 12 || [llength $cpr_dst] != 12} {
            error "ADC mailbox must bind 12 source and 12 capture registers"
        }
    }
    read_sdc constraints/page_status.sdc
    set cpr_page_src [get_regs {*u_page_status/u_transfer/src_hold[*]}]
    set cpr_page_dst [get_regs {*u_page_status/u_transfer/dst_data[*]}]
    set cpr_page_hold_names {}; set cpr_page_capture_names {}
    foreach cpr_reg $cpr_page_src { lappend cpr_page_hold_names [format {{%s}} $cpr_reg] }
    foreach cpr_reg $cpr_page_dst { lappend cpr_page_capture_names [format {{%s}} $cpr_reg] }
    puts "CPR_PAGE_REGS hold=[join $cpr_page_hold_names { }] capture=[join $cpr_page_capture_names { }]"
    if {[llength $cpr_page_src] != 12 || [llength $cpr_page_dst] != 12} {
        error "Page status mailbox must bind 12 source and 12 capture registers"
    }
    # 多时钟域关系：音频 PLL 输出（12.295 MHz）与 sd_card_clk / ext_mem_clk /
    # video_clk 之间没有相位关系，跨域点全部是构造性安全的（格雷码指针 + 两级
    # 同步器、双时钟 FIFO、准静态采样率配置）。缺这份 SDC，TD 会按同步关系去
    # 算跨域路径，凭空报 sd_card_clk -> audio SWNS -2.35ns、audio -> sd HWNS -1.54ns。
    # scripts/build_project.tcl 一直有读这一份，这里对齐，两条流程结果一致。
    read_sdc constraints/project_cdc.sdc
    report_area -file $cpr_reports/rtl_area.rpt
    commit_param -step gate
    optimize_gate -packarea $cpr_reports/gate.area
    legalize_phy_inst
    # SWUG105 single-run flow: rebuild user/IP timing objects after the
    # logical-to-physical netlist transition, before placement and routing.
    read_sdc constraints/timing.sdc
    read_sdc constraints/reset_publish.sdc
    if {$cpr_top eq "top_adc"} {
        read_sdc constraints/adc_mailbox.sdc
    }
    read_sdc constraints/page_status.sdc
    read_sdc constraints/project_cdc.sdc
    read_sdc -ip rfifo_32_32_512 ../05_lab_ex/lab_ex5_i2s/src/user_source/hdl_source/IP/afifo_32_16_256.tcl
    read_sdc -ip wfifo_32_32_512 ../05_lab_ex/lab_ex5_i2s/src/user_source/hdl_source/IP/afifo_16_32_256.tcl
    report_area -file $cpr_reports/gate_area.rpt
    if {$cpr_stage eq "full"} {
        export_db $cpr_reports/gate.db
        report_qor -step gate -file $cpr_reports/gate.qor
        # The merged background-scaling datapath misses setup by 0.040 ns
        # with this TD build's default effort. Use the documented timing
        # placement effort; retain the real clocks and path requirements.
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
        check_timing -verbose -file $cpr_reports/timing_check.rpt
        report_clock_summary -file $cpr_reports/clock_summary.rpt
        report_clock_intersection -file $cpr_reports/clock_intersection.rpt
        # EG4/TD 6.2.168116 does not support report_clock_utilization. The
        # routed log's CTS Local Wire Summary records its actual clock routes.
        report_timing_exception -file $cpr_reports/timing_exception.rpt

        foreach {clock period} {sd_card_clk 10 ext_mem_clk 25 ext_mem_clk_sft 25 video_clk 40 hdmi_5x_clk 8} {
            set actual [get_property -max PERIOD [get_clocks $clock]]
            if {abs($actual-$period)>0.001} { error "Unexpected period for $clock: $actual" }
        }
        set f [open $cpr_reports/timing_status.rpt r]
        set timing [read $f]; close $f
        if {![regexp {SWNS:\s*([-+0-9.]+)ns,\s*STNS:\s*([-+0-9.]+)ns} $timing -> sw st] ||
            ![regexp {HWNS:\s*([-+0-9.]+)ns,\s*HTNS:\s*([-+0-9.]+)ns} $timing -> hw ht]} {
            error "Cannot parse routed timing report"
        }
        if {$sw<0 || $st<0 || $hw<0 || $ht<0} { error "Timing failed: setup=$sw hold=$hw" }
        commit_param -step bitgen
        bitgen -bit $cpr_reports/$cpr_top.bit
        puts "CPR_BUILD_PASS $cpr_top setup=$sw hold=$hw"
    }

} cpr_error]} {
    puts stderr "CPR_BUILD_FAIL $cpr_top: $cpr_error"
    exit 1
}
if {$cpr_stage eq "synth"} { puts "CPR_SYNTHESIS_PASS $cpr_top" }
exit
