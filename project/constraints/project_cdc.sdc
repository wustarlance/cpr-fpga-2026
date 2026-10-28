# WAV CDC contracts. No whole-clock cuts: SD/memory/video/serial remain related.
# Only metastability-catching first stages are excluded from phase checking.
#
# 2026-10-26 合并说明（feat-audio-heartbeat-freesong ← main）：
#   本文件原先有两套写法——本分支 2026-10-24 的 set_clock_groups 整钟域剪枝，
#   与 main 2026-10-25 的"只剪第一级同步触发器 + 保留 max_delay 飞行时间"。
#   合并后统一采用 main 的做法：整钟域剪枝会让 TD 完全看不到跨域总线的
#   飞行时间，main 这一版在每个异步入口都留了 set_max_delay 上界，粒度更细，
#   也是 2026-10-25 两个顶层 +0.120/+0.159 ns 所用的同一份约束。
#   本分支新加的心跳选择端（video_clk → MCLK）在下面按同样口径补一条：
#   只剪第一级 S_heart_sync[0]，第二级及其后仍按同步路径检查。
if {[llength [get_regs -nowarn {*u_audio_wav/u_path/S_play_meta}]] > 0} {
    set_false_path -to [get_regs -nowarn {*u_audio_wav/u_path/S_play_meta}]
}
if {[llength [get_regs -nowarn {*u_audio_wav/u_path/S_mute_meta}]] > 0} {
    set_false_path -to [get_regs -nowarn {*u_audio_wav/u_path/S_mute_meta}]
}
# I_heart_en（训练模式选择）：video_clk 域电平，进 MCLK 后两级同步
# （S_heart_sync，见 rtl/audio/wav_audio_path.v §5.5）。电平保持毫秒级，
# 后面驱动的是心跳发生器和 2:1 选择器，属构造性安全。
if {[llength [get_regs -nowarn {*u_audio_wav/u_path/S_heart_sync[0]}]] > 0} {
    set_false_path -to [get_regs -nowarn {*u_audio_wav/u_path/S_heart_sync[0]}]
}
if {[llength [get_regs -nowarn {*u_audio_wav/u_path/S_stop_sd_sync[0]}]] > 0} {
    set_false_path -to [get_regs -nowarn {*u_audio_wav/u_path/S_stop_sd_sync[0]}]
}
# Optional loop first stage is handled by build.tcl via wav_loop.sdc.
# Do not put its conditional inside read_sdc: this TD still records the command
# for the ADC mapping where that logical endpoint is absent.
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
# Optional frame-total diagnostics are pruned in both shipped tops. Apply
# their bound only AFTER gate mapping in build.tcl, when both endpoints survive.
# A pre-map constraint persists even if a later conditional read skips it.

# ---------------------------------------------------------------------------
# 帧缓存读请求：video_clk -> ext_mem_clk（2026-10-26 补）
#   frame_fifo_read 的 read_req 是"保持到 read_req_ack 才撤"的握手电平，进入
#   mem 域后走 read_req_d0/d1/d2 三级链；read_req_d0 是**捕获亚稳态的第一级**，
#   和上面那些 *_meta / *_sync[0] 完全同类。
#   video_clk(40 ns) 与 ext_mem_clk(25 ns) 同源于 50 MHz 参考但相位无关，
#   所以这一级不该按"单周期建立关系"检查：请求电平连同 read_len/read_addr_index
#   在 ack 之前一直保持稳定，第二级负责把亚稳态定下来。
#   为什么现在才补：原来 sd/video/audio 之间用整组 clock group 互切，这条被顺带
#   跳过；改成端点级约束后它第一次真正参与检查（亮度/对比度改到整屏后布局扰动，
#   该路径 net delay 5.64 ns、slack -0.728ns）。只补第一级，多比特的
#   read_len/read_addr_index 仍按握手稳定性由设计保证，不加宽泛例外。
if {[llength [get_regs -nowarn {*frame_fifo_read*/read_req_d0}]] > 0} {
    set_false_path -to [get_regs -nowarn {*frame_fifo_read*/read_req_d0}]
}

# Startup prefetch-complete level: SD clock -> video clock. The boot logo stays
# selected until every discovered slot is cached (or a terminal media fault is
# reported). Only the metastability-catching first stage is asynchronous.
if {[llength [get_regs -nowarn {*boot_load_done_sync[0]}]] > 0} {
    set_false_path -to [get_regs -nowarn {*boot_load_done_sync[0]}]
}
