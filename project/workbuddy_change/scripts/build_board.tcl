# =============================================================================
# build_board.tcl —— 板级工程全流程：elaborate → 综合 → 布局 → 布线 → 时序门禁
#                    → bitgen（.bit）
#
# 用法（CWD 必须是 workbuddy_change）：
#   cd D:/ANLU/code/cpr-fpga-2026/project/workbuddy_change
#   D:/ANLU/TD_6.2.1/bin/td_commands_prompt.exe scripts/build_board.tcl
#
# 两个工程二选一，用环境变量 AB_PROJ 指定：
#   AB_PROJ=board    （默认）audio_board_top        —— HDMI 版，需要 TD SP1（加密核）
#   AB_PROJ=bringup         audio_board_bringup_top  —— 数码管+蜂鸣器版，本机可直接出位流
#
# 只到门级（约 15 s，看资源和粗时序）：set AB_STAGE=syn
#
# 产物：build_<proj>/audio_board*_top.bit
#       build_<proj>/route_timing_status.rpt / route_timing_summary.rpt
#       build_<proj>/route_area.rpt
# =============================================================================
set wbc [file normalize [file join [file dirname [file normalize [info script]]] ..]]
cd $wbc

set proj board
if {[info exists ::env(AB_PROJ)]} { set proj $::env(AB_PROJ) }

switch -- $proj {
    board {
        set al_name   audio_board.al
        set top       audio_board_top
        set adc       constraints/audio_board.adc
        set sdc       constraints/audio_board.sdc
        set out_dir   build_board
    }
    bringup {
        set al_name   audio_bringup.al
        set top       audio_board_bringup_top
        set adc       constraints/audio_bringup.adc
        set sdc       constraints/audio_bringup.sdc
        set out_dir   build_bringup
    }
    default { puts stderr "Unknown AB_PROJ: $proj"; exit 1 }
}

set ab_stage full
if {[info exists ::env(AB_STAGE)]} { set ab_stage $::env(AB_STAGE) }
if {$ab_stage ni {syn full}} { puts stderr "Invalid AB_STAGE: $ab_stage"; exit 1 }

set ab_outdir [file join $wbc $out_dir]
file mkdir $ab_outdir
puts "AUDIO_BOARD proj=$proj top=$top stage=$ab_stage cwd=[pwd] out=$ab_outdir"

if {[catch {

    import_device eagle_s20.db -package EG4S20BG256
    open_project $al_name -single_run
    load_run_param -run syn_1

    elaborate -top $top
    read_adc $adc
    read_sdc $sdc

    commit_param -step rtl
    optimize_rtl
    report_area -file "$ab_outdir/rtl_area.rpt"

    commit_param -step gate
    optimize_gate -packarea "$ab_outdir/gate.area"
    legalize_phy_inst
    report_area -file "$ab_outdir/gate_area.rpt"
    puts "AUDIO_BOARD_SYNTH_DONE"

    if {$ab_stage eq "full"} {
        commit_param -step place
        place
        commit_param -step route
        route

        update_timing -mode final
        report_timing_status  -file "$ab_outdir/route_timing_status.rpt"
        report_timing_summary -file "$ab_outdir/route_timing_summary.rpt"
        check_timing -verbose -file "$ab_outdir/route_timing_check.rpt"
        report_area -file "$ab_outdir/route_area.rpt"

        # ---- 时钟周期核对 ----
        foreach {clock period} {sd_card_clk 10 video_clk 40} {
            if {[catch {get_property -max PERIOD [get_clocks $clock]} actual]} {
                puts "WARN: clock $clock not found"
            } else {
                puts "CLOCK $clock period=$actual (expect $period)"
                if {[expr abs($actual-$period)] > 0.01} { error "Unexpected period for $clock: $actual" }
            }
        }

        # ---- 时序门禁：任何一项为负就不出位流 ----
        set f [open "$ab_outdir/route_timing_status.rpt" r]
        set timing [read $f]; close $f
        if {![regexp {SWNS:\s*([-+0-9.]+)ns,\s*STNS:\s*([-+0-9.]+)ns} $timing -> sw st] ||
            ![regexp {HWNS:\s*([-+0-9.]+)ns,\s*HTNS:\s*([-+0-9.]+)ns} $timing -> hw ht]} {
            error "Cannot parse routed timing report"
        }
        if {$sw<0 || $st<0 || $hw<0 || $ht<0} { error "Timing failed: setup=$sw hold=$hw" }

        commit_param -step bitgen
        bitgen -bit "$ab_outdir/$top.bit"
        puts "AUDIO_BOARD_PASS setup=$sw hold=$hw bit=[file join $ab_outdir $top.bit]"
    }

} ab_error]} {
    puts stderr "AUDIO_BOARD_FAIL: $ab_error"
    exit 1
}
if {$ab_stage eq "syn"} { puts "AUDIO_BOARD_SYNTH_PASS" }
exit
