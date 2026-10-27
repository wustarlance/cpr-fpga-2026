# TD 6.2.1: td_commands_prompt.exe build_fast.tcl
#
# 精简版出流脚本：只做"能生成正确 bit 的最少步骤"。
# 与 build.tcl 的差别只有两点：
#   1) 不生成调试用的中间产物（export_db 的 gate.db/route.db 共 26 MB、
#      report_qor ×3、report_area ×2、timing_summary/timing_check/
#      clock_summary/clock_intersection/timing_exception），实测这部分
#      只占总时长的 3~4%，省下来的是磁盘和干扰，不是分钟级。
#   2) 时序守卫保留：report_timing_status -> 解析 SWNS/STNS/HWNS/HTNS ->
#      任一为负即 error、不出 bit。失败时才补 timing_summary/timing_check，
#      正常构建不会为它们付钱。
# 需要完整报告时加 CPR_REPORT=1（或直接用 build.tcl）。
#
# 用法：CPR_TOP=top CPR_STAGE=full td_commands_prompt.exe build_fast.tcl
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
set cpr_verbose 0
if {[info exists ::env(CPR_REPORT)] && $::env(CPR_REPORT) eq "1"} { set cpr_verbose 1 }
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
    # 2026-10-26 时序优化：状态机改 one-hot 编码（TD LogicLevelOptimize 策略里的
    # infer_fsm one_hot）。本设计综合后 LUT 占 70%、触发器只占 37%，用触发器换
    # LUT 是净赚；更关键的是 state==X 这类译码退化成单根线，直接砍掉 .ce 树和
    # 次态锥上一级。sd_card_clk 域那两个 30/40 状态的 FSM 是最差路径的源头。
    set_param rtl infer_fsm one_hot
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
    if {$cpr_top eq "top_adc"} {
        set cpr_src [get_regs {*u_mailbox/src_hold[*]}]
        set cpr_dst [get_regs {*u_mailbox/dst_data[*]}]
        if {[llength $cpr_src] != 12 || [llength $cpr_dst] != 12} {
            error "ADC mailbox must bind 12 source and 12 capture registers"
        }
    }
    read_sdc constraints/page_status.sdc
    set cpr_page_src [get_regs {*u_page_status/u_transfer/src_hold[*]}]
    set cpr_page_dst [get_regs {*u_page_status/u_transfer/dst_data[*]}]
    if {[llength $cpr_page_src] != 12 || [llength $cpr_page_dst] != 12} {
        error "Page status mailbox must bind 12 source and 12 capture registers"
    }
    read_sdc constraints/project_cdc.sdc
    # 综合侧再压一级逻辑级数（TD LogicLevelOptimize 策略）：100 MHz 上那两条
    # BMP 读取锥是 6~9 级的控制逻辑，先让映射器少落一级，比事后布线好救。
    set_param gate map_mode          balance_explore
    set_param gate mapper_lut_delay  2200
    set_param gate merge_tiny_lut    on
    commit_param -step gate
    optimize_gate -packarea $cpr_reports/gate.area
    catch { report_qor -step gate -file $cpr_reports/gate.qor }
    catch { report_area -file $cpr_reports/gate_area.rpt }
    legalize_phy_inst
    read_sdc constraints/timing.sdc
    read_sdc constraints/reset_publish.sdc
    if {$cpr_top eq "top_adc"} {
        read_sdc constraints/adc_mailbox.sdc
    }
    read_sdc constraints/page_status.sdc
    read_sdc constraints/project_cdc.sdc
    read_sdc -ip rfifo_32_32_512 ../05_lab_ex/lab_ex5_i2s/src/user_source/hdl_source/IP/afifo_32_16_256.tcl
    read_sdc -ip wfifo_32_32_512 ../05_lab_ex/lab_ex5_i2s/src/user_source/hdl_source/IP/afifo_16_32_256.tcl
    if {$cpr_stage eq "full"} {
        # 背景缩放数据通路在默认 effort 下差 0.040 ns，必须用 timing 布局。
        # 2026-10-26 加了心跳后 slice 到 84%，那条 8 级路径（AFIFO 满标志 →
        # bmp_read_scaled 的 OUT_SEND 使能锥 → h_rem.ce）掉到 -0.217 ns，
        # 只留 opt_timing high 不够。下面这一组就是 TD 官方的 TimingHigh
        # 策略（doc/strategies/official_strategy_ph1.json），把 post_place_opt
        # 和 post_route_opt 也打开——它们专门修这种"逻辑级数不深但布线太长"的路径。
        set_param place effort              high
        set_param place opt_timing          high
        set_param place logic_level_opt     on
        set_param place aggressive_opt      20
        set_param place aggr_neighbor_dist  5
        set_param place enhanced_beeline_opt 3
        set_param place timing_driven_mode  on
        set_param place shifter_opt         on
        set_param place crit_path_opt       on
        set_param place post_place_opt      high
        set_param place split_data_from_clock on
        set_param route post_route_opt      high
        # 2026-10-26 实测否掉的方向，留档免得以后重犯（每个都单独跑过完整 P&R）：
        #   place max_fanout 32                    → slice 82%→86%，SWNS 0.188→0.007
        #   place aggr_multi_iter on +
        #   macro_performance ram_crit_path +
        #   route post_route_opt medium +
        #   route postrt_opt_extra_round 4         → SWNS -0.445（TD 失败提示里那套）
        #   route hold_margin 100                  → 保持修复一步都不做，HWNS -0.020
        #   route effort high                      → 与不改逐位相同（无效果）
        #   blur 的 INIT_COMPARE 拆两拍            → SWNS 0.188→-0.111（已回退）
        #   CongestionHigh 的密度项
        #   (target_density 0.6 / opt_max_density 50 /
        #    enhanced_gp on / non_crit_opt on /
        #    enable_congestion_recovery on)        → 布线器直接报不可布（占用已 82%，
        #                                            摊不到 60% 密度）
        # 结论：瓶颈是 82% slice 占用下的布线资源，不是布局/布线算法，
        # 调参只会在 ±0.3 ns 的噪声里来回。真要多留余量得减面积。
        commit_param -step place
        place
        commit_param -step route
        route
        update_timing -mode final
        report_timing_status -file $cpr_reports/timing_status.rpt

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
        if {$sw<0 || $st<0 || $hw<0 || $ht<0} {
            # 只在失败时才付详细报告的时间（正常构建不生成这些文件）
            catch { report_timing_summary -file $cpr_reports/timing_summary.rpt }
            catch { check_timing -verbose -file $cpr_reports/timing_check.rpt }
            error "Timing failed: setup=$sw hold=$hw"
        }
        if {$cpr_verbose} {
            catch { report_qor -step route -file $cpr_reports/route.qor }
            catch { report_clock_summary -file $cpr_reports/clock_summary.rpt }
            catch { report_timing_summary -file $cpr_reports/timing_summary.rpt }
            catch { check_timing -verbose -file $cpr_reports/timing_check.rpt }
        }
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
