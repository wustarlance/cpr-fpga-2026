# run_wave.do —— wave_painter 自检 TB（16 帧，含静音段，逐列核对）
vlib work
vmap work work
vlog -quiet -sv ../rtl/wave_painter.v ../tb/tb_wave_painter.v
vsim -c -quiet work.tb_wave_painter
run -all
quit -f
