# Read a routed checkpoint only: no optimize/place/route/bitgen/download.
cd [file dirname [file normalize [info script]]]
set cpr_top $::env(CPR_TOP)
if {$cpr_top ni {top top_adc}} { error "Unsupported CPR_TOP" }
set cpr_checkpoint build/$cpr_top/route.db
if {![file isfile $cpr_checkpoint]} { error "Routed checkpoint missing" }
if {[catch {
    import_device eagle_s20.db -package EG4S20BG256
    open_project project.al -single_run
    import_db $cpr_checkpoint
    update_timing -mode final
    report_route_status -drc
    set cpr_prefix ""
    if {$cpr_top eq "top_adc"} { set cpr_prefix "u_board/" }
    # TD 6.2.168116 crashes when report_cells prints this SDRAM macro's
    # inout connections. Its location is retained in the exported PNL.
    foreach cpr_cell {sys_pll_m0/pll_inst video_pll_m0/pll_inst u_audio_pll/pll_inst} {
        if {[llength [get_cells ${cpr_prefix}${cpr_cell}]] != 1} {
            error "Expected exactly one PLL: ${cpr_prefix}${cpr_cell}"
        }
        puts "CPR_AUDIT_CELL ${cpr_prefix}${cpr_cell}"
        report_cells [get_cells ${cpr_prefix}${cpr_cell}] -connection -pin_loc
    }
    foreach cpr_net {sys_pll_m0/clk0_out video_pll_m0/clk0_out u_audio_pll/clk0_out U3/u2_ram/SDRAM_CLK} {
        if {[llength [get_nets ${cpr_prefix}${cpr_net}]] != 1} {
            error "Expected exactly one clock net: ${cpr_prefix}${cpr_net}"
        }
        puts "CPR_AUDIT_NET ${cpr_prefix}${cpr_net}"
        report_nets [get_nets ${cpr_prefix}${cpr_net}] -connection -mode final -timing -hold -pin_output_limit 8
    }
    puts "CPR_AUDIT_PORTS [get_ports *]"
    # Use a variable filename: this TD command does not preserve a nested
    # [file join ...] filename argument in the local implementation.
    set cpr_audit_output $::env(CPR_AUDIT_OUTPUT)
    write_pnl $cpr_audit_output/routed.pnl -clk -v
    puts "CPR_PHYSICAL_AUDIT_DONE $cpr_top"
} cpr_audit_error]} {
    puts stderr "CPR_PHYSICAL_AUDIT_FAILED $cpr_audit_error"
    exit 1
}
exit
