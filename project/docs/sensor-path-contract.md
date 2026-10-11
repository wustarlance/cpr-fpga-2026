# ADC sensor pipeline contract

`cpr_sensor_path` connects the real `adc_ctrl`, `sample_mailbox`, `pressure_normalize` and `peak_detect` modules. The FPGA board top separately instantiates `EG_PHY_ADC`. ADC clock is the existing approximately 12.295 MHz audio PLL output; application clock is the 25 MHz video clock. The board's 50 MHz input feeds the PLLs; it is not the application clock. This pipeline generates no clock and includes no ADC primitive or pin assignment.

## Interfaces and reset

`adc_eoc`, `adc_dout[11:0]`, `adc_soc`, `adc_pd` and `adc_channel[2:0]` belong to `adc_clk`. `enabled`, `clear_session`, `raw_valid/raw_data`, `peak_event/peak_grade/peak_value` and `sensor_fault` belong to `app_clk`. Valid and peak-event are single application-clock pulses; words remain stable between their associated events, except reset or cancellation of the detector state.

Assert both domain resets together. Deassert each synchronously in its own clock domain. The mailbox toggle handshake does not support one-sided reset: resetting a source or destination alone can lose or replay a transaction. A common reset discards in-flight samples and presses, resets filtering and clears hardware faults. See `adc-contract.md` for request, EOC and timeout behavior.

## Sample transfer and pressure units

The one-entry mailbox accepts a source sample when `adc_sample_valid && !mailbox_busy`, holds its complete 12-bit word, and waits for application capture/acknowledgment. A new source sample while busy is discarded and latches an overflow fault. At default 61-clock sample spacing and a running 25 MHz application clock, the handshake has ample nominal service time; clock stopping or a changed frequency still requires a rate/overflow analysis. The held data path requires appropriate TD CDC constraints and post-route review; passing functional simulation does not model metastability or prove physical delay.

Defaults assume increasing force produces decreasing ADC codes. Pressure code is `max(3000 - raw_code, 0)`; the configurable `FALLING_WITH_FORCE=0` reverses that polarity. `FILTER_SHIFT=2` applies a four-valid-sample moving average with a four-sample warm-up; `FILTER_SHIFT=0` bypasses it. No invalid cycle enters the average. These are pressure codes, not calibrated displacement in millimetres or centimetres.

After reset, clear or re-enable, detection first requires a valid filtered release at or below code 100. Trigger is code 150. A press completes only on a subsequent full release at or below 100, producing one `peak_event`. Peak codes below 800 grade shallow (1), 800 through 1600 grade target (2), above 1600 grade deep (3). Grade 0 is unknown/reset. A partial dip that remains above release retains the same active press and cannot cause a second count. Holding a sensor through clear, disable or reset cannot create a new press before an observed release.

## Hardware fault policy

ADC timeout or illegal ADC parameters latch `adc_fault_sticky` in the ADC domain. The mailbox separately latches `overflow_sticky`. Their OR is synchronized as a persistent level through two application registers. Once `sensor_fault` is observed, the detector cancels the current press and inhibits all subsequent peak events until a common reset. An additional event gate suppresses output on the application cycle the synchronized fault becomes high. The finite detection/synchronization latency before fault observation is not an instantaneous cross-domain guarantee.

`clear_session` resets press state and last peak outputs; it does not clear ADC or mailbox hardware faults. Raw samples can continue after a fault for diagnostics. Successful ADC recovery and later raw samples do not re-enable counting automatically. Application UI should report the fault and require a controlled common reset after correcting its cause.

## Connection to the training core

The board top selects `cpr_control #(.USE_PRESS_EVENTS(USE_ADC))`. With `USE_ADC=1` (`top_adc`), `peak_event`, `peak_grade` and pipeline `sensor_fault` connect directly to `press_event`, `press_grade` and `press_fault`. These ports and the training core share the 25 MHz application domain; no further CDC or conversion to four-bit contact codes is needed. `USE_ADC=0` selects the independently debounced contact-code path and ties the event inputs to zero. See the [training core contract](training-contract.md) for both encodings, pulse requirements, fault rejection and first-enabled-cycle cancellation.

The board top combines external reset and PLL lock loss into a common reset cause, then synchronizes release per domain. Session clear cancels application press state without resetting the ADC/mailbox protocol. The detector's `in_press` is intentionally internal and unconnected at the pipeline boundary; adding a UI hold indicator would require a separate interface change. Source wiring is in [the board top](../rtl/top_tf_hdmi_audio.v) and [cpr_control](../rtl/cpr_control.v).

## Executable checks and physical limits

`tests/sim/tb/tb_cpr_sensor_path.v` drives an independently clocked 12.295 MHz ADC model and 25 MHz application domain. It checks ADC sample words, accepted mailbox ordering, raw event widths, four-sample filtering, and known peak events. Scenarios include target pressure, partial release, clear while held, disable/re-enable while held, reset while held, fresh release arming, ADC timeout and sticky cancellation, and mailbox overflow during application-clock absence. Failures use `$fatal(1, ...)`; successful completion emits `PASS: tb_cpr_sensor_path`.

The model checks digital timing only. Real channel enables, board pads, input voltage/code polarity, reference voltage, analog noise and force/displacement calibration need board measurements. The source ADC clock limit and sparse PD behavior remain governed by the official TN304 guide; the pure RTL pipeline does not establish hardware accuracy or timing closure.
