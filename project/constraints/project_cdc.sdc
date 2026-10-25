# WAV CDC contracts. No whole-clock cuts: SD/memory/video/serial remain related.
# Only metastability-catching first stages are excluded from phase checking.
if {[llength [get_regs -nowarn {*u_audio_wav/u_path/S_play_meta}]] > 0} {
    set_false_path -to [get_regs -nowarn {*u_audio_wav/u_path/S_play_meta}]
}
if {[llength [get_regs -nowarn {*u_audio_wav/u_path/S_mute_meta}]] > 0} {
    set_false_path -to [get_regs -nowarn {*u_audio_wav/u_path/S_mute_meta}]
}
if {[llength [get_regs -nowarn {*u_audio_wav/u_path/S_stop_sd_sync[0]}]] > 0} {
    set_false_path -to [get_regs -nowarn {*u_audio_wav/u_path/S_stop_sd_sync[0]}]
}
if {[llength [get_regs -nowarn {*u_audio_wav/u_path/S_loop_sd_sync[0]}]] > 0} {
    set_false_path -to [get_regs -nowarn {*u_audio_wav/u_path/S_loop_sd_sync[0]}]
}
if {[llength [get_regs -nowarn {*u_audio_wav/u_path/S_tog_m[0]}]] > 0} {
    set_false_path -to [get_regs -nowarn {*u_audio_wav/u_path/S_tog_m[0]}]
}
if {[llength [get_regs -nowarn {*u_audio_wav/u_path/S_cfg_sync[0]}]] > 0} {
    set_false_path -to [get_regs -nowarn {*u_audio_wav/u_path/S_cfg_sync[0]}]
}
if {[llength [get_regs -nowarn {*u_audio_wav/u_path/S_tog_sync[0]}]] > 0} {
    set_false_path -to [get_regs -nowarn {*u_audio_wav/u_path/S_tog_sync[0]}]
}

# Gray flight < one SOURCE period: SD 10 ns, MCLK 81.334 ns.
# Exclude hold only at first synchronizers; keep max flight/skew bounds live.
set_max_delay -from [get_regs -nowarn {*u_audio_wav/u_path/u_pcm_fifo/S_wgray[*]}] -to [get_regs -nowarn {*u_audio_wav/u_path/u_pcm_fifo/S_wgray_r1[*]}] 9.7 -datapath_only
set_false_path -hold -from [get_regs -nowarn {*u_audio_wav/u_path/u_pcm_fifo/S_wgray[*]}] -to [get_regs -nowarn {*u_audio_wav/u_path/u_pcm_fifo/S_wgray_r1[*]}]
set_max_delay -from [get_regs -nowarn {*u_audio_wav/u_path/u_pcm_fifo/S_rgray[*]}] -to [get_regs -nowarn {*u_audio_wav/u_path/u_pcm_fifo/S_rgray_w1[*]}] 80.9 -datapath_only
set_false_path -hold -from [get_regs -nowarn {*u_audio_wav/u_path/u_pcm_fifo/S_rgray[*]}] -to [get_regs -nowarn {*u_audio_wav/u_path/u_pcm_fifo/S_rgray_w1[*]}]

# PCM held >20 us; toggle crosses two video stages before capture. Bound data
# to one 40 ns destination cycle, leaving a full extra cycle of margin.
if {[llength [get_regs -nowarn {*u_audio_wav/u_path/S_aud_frame[*]}]] > 0} {
    set_max_delay -from [get_regs -nowarn {*u_audio_wav/u_path/S_frame_m[*]}] -to [get_regs -nowarn {*u_audio_wav/u_path/S_aud_frame[*]}] 40 -datapath_only
    set_false_path -hold -from [get_regs -nowarn {*u_audio_wav/u_path/S_frame_m[*]}] -to [get_regs -nowarn {*u_audio_wav/u_path/S_aud_frame[*]}]
}

# Header snapshots held across reader reset/reparse, with two MCLK stages
# before capture. 80 ns < one 81.334 ns destination cycle. Updates require
# another complete SD header transfer, not arbitrary per-cycle changes.
set_max_delay -from [get_regs -nowarn {*u_audio_wav/u_path/S_cfg_rate_hold[*]}] -to [get_regs -nowarn {*u_audio_wav/u_path/S_sr[*]}] 80 -datapath_only
set_false_path -hold -from [get_regs -nowarn {*u_audio_wav/u_path/S_cfg_rate_hold[*]}] -to [get_regs -nowarn {*u_audio_wav/u_path/S_sr[*]}]
if {[llength [get_regs -nowarn {*u_audio_wav/u_path/S_cfg_total_hold[*]}]] > 0 &&
    [llength [get_regs -nowarn {*u_audio_wav/u_path/S_ftotal[*]}]] > 0} {
    set_max_delay -from [get_regs -nowarn {*u_audio_wav/u_path/S_cfg_total_hold[*]}] -to [get_regs -nowarn {*u_audio_wav/u_path/S_ftotal[*]}] 80 -datapath_only
    set_false_path -hold -from [get_regs -nowarn {*u_audio_wav/u_path/S_cfg_total_hold[*]}] -to [get_regs -nowarn {*u_audio_wav/u_path/S_ftotal[*]}]
}
