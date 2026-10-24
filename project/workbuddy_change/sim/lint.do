# lint.do —— 用 ModelSim 编译 TD 综合用的同一份文件集，并 elaborate audio_tmg_top
# 目的：确认「TD 能综合的 13 个文件」在 ModelSim 里也能无错 elaborate，
#       排除只能在某一侧通过的写法（多为位宽/隐式声明差异）。
vlib work
vmap work work
vlog -quiet -sv \
  ../../rtl/audio/audio_arc_calculate.v \
  ../../rtl/audio/pcm_fifo.v \
  ../../rtl/audio/pcm_frame_tick.v \
  ../../rtl/audio/pcm_player.v \
  ../../rtl/audio/wav_reader.v \
  ../../rtl/audio/wav_audio_path.v \
  ../../rtl/audio/wav_audio_sd_top.v \
  ../../vendor/SD/sd_card_top.v \
  ../../vendor/SD/sd_card_cmd.v \
  ../../vendor/SD/sd_card_sec_read_write.v \
  ../../vendor/SD/spi_master.v \
  ../rtl/wave_painter.v \
  ../rtl/audio_tmg_top.v

vsim -c -quiet work.audio_tmg_top -novopt
puts "LINT_ELAB_PASS"
quit -f
