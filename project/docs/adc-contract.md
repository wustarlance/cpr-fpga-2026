# Internal ADC controller contract

`rtl/adc_ctrl.v` is synthesizable Verilog-2001 control logic. The board wrapper separately instantiates `EG_PHY_ADC`, enables CH1 and VREF, and supplies the existing audio PLL clock. No fabric-generated clock is created by this controller.

## Clock and reset

All ports belong to the ADC clock domain. Defaults are `ADC_CLK_HZ=12295082`, `SAMPLE_HZ=200000`, `CHANNEL=1`, `TIMEOUT_CYCLES=64`. The frequency value describes the actual approximately 12.295 MHz clock; verify the selected PLL output and timing report. EOC and DOUT are synchronous to this same clock. The board's pipeline transfers `sample_valid` with the coherent `sample_data` word through a mailbox into the 25 MHz video/application domain. Independent bit synchronizers cannot preserve an ADC word.

Reset asserts asynchronously, clears the last sample and request state, and holds `adc_pd=1`. Its release must already be synchronized to this clock by the wrapper. Conversion interrupted by reset is discarded. After release, the first active clock keeps PD high; five clock periods later the controller raises SOC. An ADC clock edge consumes a registered SOC pulse on the following edge.

## Request and completion

SOC, sample-valid and normal-operation fault are each one controller-clock pulse. Channel is constant. Each SOC-to-SOC output interval is `round(ADC_CLK_HZ / SAMPLE_HZ)` whole clocks with no additional GAP delay. Default interval is 61 clocks, approximately 201558.72 samples/s; 1 kHz configuration uses 12295 clocks, approximately 1000.0067 samples/s. The roundoff is deliberate and must be reported rather than labeling the hardware rate exactly 200 kHz.

Only EOC during an outstanding request produces one sample-valid pulse. The 12-bit input word is captured on that EOC edge; the last successful sample remains stable otherwise. EOC while idle is ignored. EOC already high when starting a request must first return low before it can complete the new request. The controller waits for EOC and does not synthesize completion from the published conversion length.

If a scheduled SOC slot arrives while a conversion remains outstanding, that slot is skipped; requests never overlap. The regular schedule keeps advancing. A sparse slot also requires its PD preparation to have occurred while the ADC was idle or completing the preceding request; otherwise it is skipped. No result is fabricated for a skipped slot, and the scheduled PD action does not abort an outstanding conversion. If EOC has not arrived within `TIMEOUT_CYCLES` after the SOC output edge, fault pulses, PD clears the old conversion, and a recovery SOC follows five clocks later. Recovery restarts the schedule, so interval guarantees apply to healthy operation. On the timeout boundary a valid armed EOC takes priority over timeout.

Static illegal parameters hold PD high and fault high with no SOC or valid data. Legal values require clock 1..16000000 Hz, sample rate 1..1000000 Hz, channel 0..7, rounded interval at least 18 clocks (23 clocks for sparse sampling), and timeout at least 18 clocks. The 18-clock minimum accounts for registered SOC and synchronous reception of the 16-clock public model; sparse mode also reserves five clocks for the PD action after completion. The ADC's published 1 MS/s maximum does not guarantee this wrapper can provide that rate at every ADC clock.

## Sparse sampling and PD

TN304_1.3 PDF page 4 recommends SOC intervals below 10 microseconds. For an actual integer request interval at least 10 microseconds, this controller raises PD for one clock, with its output rising edge five clocks before the SOC output rising edge. PD is otherwise low during normal conversion. This implements the documented brief PD action; it does not interpret the guide as a five-clock-wide PD assertion. Startup and timeout recovery also prime the ADC through PD.

## Verification boundary

`tests/sim/stubs/eg_phy_adc_timing_model.v` is an original digital stimulus model. Its counter follows the public, unprotected TD model: accept SOC while idle, sample after four subsequent clock edges, complete after sixteen subsequent edges, pulse EOC for one clock, ignore SOC while busy, and asynchronously clear on PD. It models no analog transfer function, noise, pad mux, channel-enable configuration, reference accuracy, metastability, effective resolution or mechanical calibration. No protected source is decrypted or reproduced.

`tb_adc_ctrl.v` checks exact fast and sparse intervals, PD placement, sample counts and contents, acquisition before completion, ignored busy SOC, ignored unsolicited EOC, delayed completion, timeout and recovery, and reset cancellation. Assertions terminate with `$fatal(1, ...)`; only successful completion emits `PASS: tb_adc_ctrl`. Simulation proves the digital contract exercised by those scenarios. Hardware channel, voltage/code direction, reference voltage, sample accuracy and FSR displacement calibration remain physical checks.

The verified BG256 CH1 pad is M10, routed to J1 pin 16 / GPIOA_13. ADC_VREF is the separate L11 pad, not VCCIO8. The pressure front end must supply an electrically valid voltage and a separately defined/calibrated pressure or displacement interface.

## Source evidence

Original local sources were kept as PDF: `E:/BaiduNetdiskDownload/HX4S20_Contest_202606/6_EG4S20数据手册/EG4S内部ADC使用指南.pdf` (TN304_1.3, physical PDF pages 1-4), `EG4S20数据手册.pdf` (pages 19-20), the HDL2410 board manual and board schematics. Public digital timing source: `E:/sim_release/eg4/eg_phy_adc.v`, unprotected lines 115-116, 215-247 and 254-289. The installed `anlogic-hx4s20c` skill source catalog records the original document hashes. This contract is an implementation note, not an official Anlogic document.
