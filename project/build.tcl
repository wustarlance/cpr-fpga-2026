# TD 6.2.1: td_commands_prompt.exe build.tcl
# CPR_TOP=top (board demo, default) or top_adc (uncalibrated sensor).
# Full build by default. CPR_STAGE=synth selects synthesis only; never programs hardware.
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
    # Inspect the PCM mailbox here, but bind WAV CDC constraints only AFTER
    # gate mapping below. Constant controls (e.g. ADC top loop) are pruned
    # during mapping; pre-map exceptions would survive with invalid endpoints.
    set cpr_pcm_hold [get_regs {*u_audio_wav/u_path/S_frame_m[*]}]
    set cpr_pcm_capture [get_regs {*u_audio_wav/u_path/S_aud_frame[*]}]
    puts "CPR_PCM_REGS hold=[llength $cpr_pcm_hold] capture=[llength $cpr_pcm_capture]"
    if {([llength $cpr_pcm_hold] != 0 || [llength $cpr_pcm_capture] != 0) &&
        ([llength $cpr_pcm_hold] != 48 || [llength $cpr_pcm_capture] != 48)} {
        error "Default WAV audio must bind 48 coherent PCM source and capture registers"
    }
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
    # These video -> SD controls are caught by two-stage synchronizers. Only
    # their first-stage HOLD check is inapplicable: arrival near an edge may
    # metastabilize that stage, while stage two supplies the settling cycle.
    # Retain all setup checks (including the selector bus's one-cycle flight
    # bound), all second stages, RAM paths and the related PLL clocks.
    # S_sel_meta is followed by S_sel_sync and an eight-cycle stable-code
    # filter. Do not cut S_sel_sync or the filter/capture registers.
    # Resolve logical endpoints after mapping; packed physical cell names can
    # misleadingly mention the visualizer, background RAM or frame publisher.
    foreach {cpr_first_pattern cpr_second_pattern cpr_count} {
        {*sd_card_bmp_m0/u_key_next/button_sync0} {*sd_card_bmp_m0/u_key_next/button_sync1} 1
        {*sd_card_bmp_m0/u_key_prev/button_sync0} {*sd_card_bmp_m0/u_key_prev/button_sync1} 1
        {*sd_card_bmp_m0/auto_sync[0]} {*sd_card_bmp_m0/auto_sync[1]} 1
        {*sd_card_bmp_m0/training_sync[0]} {*sd_card_bmp_m0/training_sync[1]} 1
        {*sd_card_bmp_m0/train_next_sync[0]} {*sd_card_bmp_m0/train_next_sync[1]} 1
        {*sd_card_bmp_m0/train_prev_sync[0]} {*sd_card_bmp_m0/train_prev_sync[1]} 1
        {*u_audio_wav/u_track/S_sel_meta[*]} {*u_audio_wav/u_track/S_sel_sync[*]} 3
    } {
        set cpr_first_regs [get_regs -nowarn $cpr_first_pattern]
        set cpr_second_regs [get_regs -nowarn $cpr_second_pattern]
        puts "CPR_SD_CONTROL_CDC first=$cpr_first_regs second=$cpr_second_regs expected=$cpr_count"
        if {[llength $cpr_first_regs] != $cpr_count || [llength $cpr_second_regs] != $cpr_count} {
            error "Unexpected SD control synchronizer endpoints: $cpr_first_pattern"
        }
        set_false_path -hold -to $cpr_first_regs
    }
    # Use an ordinary Tcl condition around reading a static SDC. In this TD,
    # an if inside read_sdc does not prevent an absent loop endpoint from
    # becoming an invalid exception in the ADC implementation.
    set cpr_loop_first [get_regs {*u_audio_wav/u_path/S_loop_sd_sync[0]}]
    puts "CPR_OPTIONAL_LOOP_REGS [llength $cpr_loop_first]"
    if {[llength $cpr_loop_first] > 0} {
        read_sdc constraints/wav_loop.sdc
    }
    # Total-frame status is not exposed by either shipped top. Do not attach
    # this optional bound before mapping: its source can then be removed while
    # TD retains the constraint. Bind only surviving physical endpoints.
    set cpr_total_hold [get_regs -nowarn {*u_audio_wav/u_path/S_cfg_total_hold[*]}]
    set cpr_total_capture [get_regs -nowarn {*u_audio_wav/u_path/S_ftotal[*]}]
    puts "CPR_OPTIONAL_TOTAL_REGS hold=[llength $cpr_total_hold] capture=[llength $cpr_total_capture]"
    if {[llength $cpr_total_hold] > 0 && [llength $cpr_total_capture] > 0} {
        set_max_delay -from $cpr_total_hold -to $cpr_total_capture 80 -datapath_only
        set_false_path -hold -from $cpr_total_hold -to $cpr_total_capture
    }
    read_sdc -ip rfifo_32_32_512 ../05_lab_ex/lab_ex5_i2s/src/user_source/hdl_source/IP/afifo_32_16_256.tcl
    read_sdc -ip wfifo_32_32_512 ../05_lab_ex/lab_ex5_i2s/src/user_source/hdl_source/IP/afifo_16_32_256.tcl
    report_area -file $cpr_reports/gate_area.rpt
    if {$cpr_stage eq "full"} {
        export_db $cpr_reports/gate.db
        report_qor -step gate -file $cpr_reports/gate.qor
        # The merged background-scaling datapath misses setup by 0.040 ns
        # with this TD build's default effort. Use the documented timing
        # placement effort; retain the real clocks and path requirements.
        #
        # 2026-10-27：试过两条更强的路都没用，留档免得重试——
        #   1) TD 官方 TimingHigh 整套（build_fast.tcl 那 12 条）：触发增量合法化，
        #      撞 PHY-8023（holdbuf 落在非法位置）→ RUN-8102，带不带
        #      route post_route_opt high 都一样；
        #   2) 只加 set_param place effort high：结果与原始配置逐位相同（无效果）。
        # 真正的问题在结构：bmp_blur_background 的坐标钳位串在 read_addr_q 的 D 端
        # （11 级锥），已改为寄存器预计算，见该模块 2026-10-27 注释。
        set_param place opt_timing high
        commit_param -step place
        # 2026-10-27：高扇出网优化。先诊断再动手——实测（report_routing_resource）
        # 布线资源平均只用了 27.18%，report_congestion level>=1 无任何拥挤通道，
        # 说明瓶颈不是布线通道不够，而是 85.3% slice 占用下单元被摊开、网线太长
        # （榜首 state[3] 扇出 64、单跳 1.475 ns；前 10 条路径 56%~80% 是线延迟）。
        # 所以过去调 route effort / post_route_opt 全部无效果——路由器不是瓶颈。
        #
        # hfn_opt_effort 是官方 TimingUltra 相对 TimingHigh 的唯一增量参数，作用是
        # 让布局阶段复制高扇出网、就近驱动。单独打开实测（其余条件不变）：
        #   SWNS 0.114 → 0.197 ns（+73%），HWNS 0.003 不变，
        #   榜首路径 Max Fanout 64 → 8、线延迟占比 80% → 56%，
        #   代价 slices 85.30% → 86.03%（+72 slices）。
        # 净收益明确且是全局的（整条路径带 0.114~0.213 一起抬到 0.197~0.254），
        # 故默认开启；要退回历史行为：CPR_HFN_EFFORT=off 再构建。
        set cpr_hfn high
        if {[info exists ::env(CPR_HFN_EFFORT)]} { set cpr_hfn $::env(CPR_HFN_EFFORT) }
        if {$cpr_hfn ne "" && $cpr_hfn ne "off"} {
            set_param place hfn_opt_effort $cpr_hfn
            commit_param -step place
        }
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
