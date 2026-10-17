# Metronome select crosses from the 25 MHz video domain into the 12.295 MHz
# audio domain. It is a slow, human-rate control, captured by the two-flop
# synchronizer in cpr_audio_tone_i2s. Only the first stage is exempt; the
# second-stage capture and all downstream phase math stay timed.
#
# Loaded after optimize_rtl for both tops, because get_regs resolves register
# objects only after RTL optimization.
set_false_path -to [get_regs {*u_cpr_audio_tone/metronome_meta}]
