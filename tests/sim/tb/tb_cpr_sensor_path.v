`timescale 1ns / 1ps
module tb_cpr_sensor_path;
    reg adc_clk = 0;
    always #40.666667 adc_clk = ~adc_clk;
    reg app_clk = 0;
    reg app_clock_running = 1;
    initial begin
        #3;
        forever begin
            #20;
            if (app_clock_running)
                app_clk = ~app_clk;
            else
                app_clk = 0;
        end
    end
    reg adc_rst_n = 0;
    reg app_rst_n = 0;
    reg enabled = 1;
    reg clear_session = 0;
    reg [11:0] analog_code = 12'd3000;
    reg suppress_eoc = 0;
    wire model_eoc;
    wire [11:0] model_data;
    wire adc_soc, adc_pd;
    wire [2:0] adc_channel;
    wire peak_event;
    wire [1:0] peak_grade;
    wire [11:0] peak_value;
    wire raw_valid;
    wire [11:0] raw_data;
    wire sensor_fault;

    cpr_sensor_path dut (
        .adc_clk(adc_clk), .adc_rst_n(adc_rst_n),
        .app_clk(app_clk), .app_rst_n(app_rst_n),
        .adc_eoc(suppress_eoc ? 1'b0 : model_eoc), .adc_dout(model_data),
        .adc_soc(adc_soc), .adc_pd(adc_pd), .adc_channel(adc_channel),
        .enabled(enabled), .clear_session(clear_session),
        .peak_event(peak_event), .peak_grade(peak_grade),
        .peak_value(peak_value), .raw_valid(raw_valid), .raw_data(raw_data),
        .sensor_fault(sensor_fault)
    );
    eg_phy_adc_timing_model adc_model (
        .clk(adc_clk), .pd(adc_pd), .s(adc_channel), .soc(adc_soc),
        .analog_code(analog_code), .eoc(model_eoc), .dout(model_data)
    );

    reg [11:0] accepted_words [0:8191];
    integer accepted_write = 0;
    integer accepted_read = 0;
    integer source_samples = 0;
    integer dropped_samples = 0;
    reg [11:0] acquired_code = 0;
    reg acquisition_pending = 0;
    // The expected ADC word comes from the actual acquisition boundary, not
    // the source value at completion or destination capture.
    always @(posedge adc_clk) begin
        if (!adc_rst_n) begin
            accepted_write = 0;
            acquisition_pending = 0;
        end else begin
            if (adc_pd)
                acquisition_pending = 0;
            else if (adc_model.counter == 4) begin
                acquired_code = analog_code;
                acquisition_pending = 1;
            end
            // Mailbox accepts the registered ADC valid on this clock edge.
            if (dut.adc_sample_valid) begin
                if (dut.mailbox_busy)
                    dropped_samples = dropped_samples + 1;
                else begin
                    if (accepted_write >= 8192)
                        $fatal(1, "pipeline source scoreboard overflow");
                    accepted_words[accepted_write] = dut.adc_sample_data;
                    accepted_write = accepted_write + 1;
                end
            end
        end
        #1;
        if (adc_rst_n && dut.adc_sample_valid) begin
            if (!acquisition_pending || dut.adc_sample_data !== acquired_code)
                $fatal(1, "pipeline ADC acquisition mismatch: got %0d expected %0d",
                    dut.adc_sample_data, acquired_code);
            source_samples = source_samples + 1;
            acquisition_pending = 0;
        end
    end

    integer raw_samples = 0;
    integer filtered_samples = 0;
    integer peak_events = 0;
    integer expected_peak_count = 0;
    reg [1:0] expected_grades [0:15];
    reg [11:0] expected_values [0:15];
    integer history [0:3];
    integer history_index = 0;
    integer history_count = 0;
    integer history_sum = 0;
    integer normalized_word;
    integer reference_pressure = 0;
    reg reference_valid = 0;
    reg previous_raw_valid = 0;
    reg previous_peak_event = 0;
    reg previous_fault = 0;
    reg [11:0] previous_raw_data = 0;
    integer i;

    always @(posedge app_clk) begin
        if (!app_rst_n) begin
            accepted_read = 0;
            history_index = 0;
            history_count = 0;
            history_sum = 0;
            reference_pressure = 0;
            reference_valid = 0;
            previous_raw_valid = 0;
            previous_peak_event = 0;
            previous_fault = 0;
            previous_raw_data = 0;
            for (i = 0; i < 4; i = i + 1)
                history[i] = 0;
        end else begin
            // Reference average uses the four most recent VALID raw samples.
            reference_valid = 0;
            if (raw_valid) begin
                normalized_word = raw_data < 3000 ? 3000 - raw_data : 0;
                history_sum = history_sum - history[history_index] + normalized_word;
                history[history_index] = normalized_word;
                history_index = (history_index + 1) % 4;
                if (history_count < 4)
                    history_count = history_count + 1;
                if (history_count == 4) begin
                    reference_valid = 1;
                    reference_pressure = history_sum / 4;
                end
            end
        end
        #2;
        if (app_rst_n) begin
            if ((^{raw_valid, peak_event, sensor_fault}) === 1'bx)
                $fatal(1, "unknown pipeline event/fault output");
            if ((previous_raw_valid && raw_valid) ||
                (previous_peak_event && peak_event))
                $fatal(1, "pipeline event wider than one application clock");
            if (raw_valid) begin
                if (accepted_read >= accepted_write ||
                    raw_data !== accepted_words[accepted_read])
                    $fatal(1, "mailbox word/order mismatch at item %0d: got %0d",
                        accepted_read, raw_data);
                accepted_read = accepted_read + 1;
                raw_samples = raw_samples + 1;
                previous_raw_data = raw_data;
            end else if (raw_data !== previous_raw_data)
                $fatal(1, "raw data changed without raw-valid");
            if (dut.pressure_valid !== reference_valid)
                $fatal(1, "filter valid/warm-up mismatch");
            if (dut.pressure_valid) begin
                if (dut.pressure_data !== reference_pressure[11:0])
                    $fatal(1, "pressure filter mismatch: got %0d expected %0d",
                        dut.pressure_data, reference_pressure);
                filtered_samples = filtered_samples + 1;
            end
            if (sensor_fault && peak_event)
                $fatal(1, "peak event escaped sticky sensor fault");
            if (previous_fault && !sensor_fault)
                $fatal(1, "sensor fault cleared without common reset");
            if (peak_event) begin
                if (peak_events >= expected_peak_count)
                    $fatal(1, "unexpected/duplicate peak event %0d", peak_events);
                if (peak_grade !== expected_grades[peak_events] ||
                    peak_value !== expected_values[peak_events])
                    $fatal(1, "peak %0d mismatch: grade %0d value %0d expected %0d/%0d",
                        peak_events, peak_grade, peak_value,
                        expected_grades[peak_events], expected_values[peak_events]);
                peak_events = peak_events + 1;
            end
            previous_raw_valid = raw_valid;
            previous_peak_event = peak_event;
            previous_fault = sensor_fault;
        end else if (raw_valid !== 0 || peak_event !== 0 || sensor_fault !== 0)
            $fatal(1, "pipeline outputs did not reset");
    end

    task hold_code;
        input [11:0] code;
        input integer samples;
        integer initial_samples;
        begin
            @(negedge adc_clk);
            analog_code = code;
            initial_samples = raw_samples;
            wait (raw_samples >= initial_samples + samples);
            // Drain normalize -> detector pipeline before phase assertions.
            repeat (5) @(negedge app_clk);
        end
    endtask

    task expect_peak;
        input [1:0] grade;
        input [11:0] value;
        begin
            expected_grades[expected_peak_count] = grade;
            expected_values[expected_peak_count] = value;
            expected_peak_count = expected_peak_count + 1;
        end
    endtask

    task common_reset;
        begin
            @(negedge adc_clk);
            adc_rst_n = 0;
            app_rst_n = 0;
            repeat (4) @(negedge adc_clk);
            // Assertion is common; release is away from each active edge.
            adc_rst_n = 1;
            @(negedge app_clk);
            app_rst_n = 1;
        end
    endtask

    task pulse_clear;
        begin
            @(negedge app_clk);
            clear_session = 1;
            @(negedge app_clk);
            clear_session = 0;
        end
    endtask

    integer dropped_before;
    initial begin
        common_reset;
        hold_code(12'd3200, 8); // above baseline clamps to zero pressure
        hold_code(12'd3000, 8);
        hold_code(12'd2000, 12);
        hold_code(12'd2850, 12); // partial dip: force 150 stays above release 100
        if (peak_events != 0)
            $fatal(1, "partial release counted a press");
        hold_code(12'd1900, 12);
        expect_peak(2'd2, 12'd1100);
        hold_code(12'd3000, 12);
        if (peak_events != 1)
            $fatal(1, "full release did not complete one target press");

        // Clear while held: holding cannot start a new press after clear.
        hold_code(12'd2000, 12);
        pulse_clear;
        hold_code(12'd2000, 12);
        hold_code(12'd3000, 12);
        if (peak_events != 1)
            $fatal(1, "clear while held created a completion");
        hold_code(12'd2600, 12);
        expect_peak(2'd1, 12'd400);
        hold_code(12'd3000, 12);
        if (peak_events != 2)
            $fatal(1, "fresh shallow press after clear did not complete");

        // Disable and re-enable while held require a release before re-arming.
        hold_code(12'd1000, 12);
        @(negedge app_clk);
        enabled = 0;
        hold_code(12'd1000, 12);
        @(negedge app_clk);
        enabled = 1;
        hold_code(12'd1000, 12);
        hold_code(12'd3000, 12);
        if (peak_events != 2)
            $fatal(1, "re-enable while held counted a cancelled press");
        hold_code(12'd1000, 12);
        expect_peak(2'd3, 12'd2000);
        hold_code(12'd3000, 12);
        if (peak_events != 3)
            $fatal(1, "fresh deep press did not complete");

        // Common restart while held does not arm until another release.
        hold_code(12'd2000, 12);
        common_reset;
        hold_code(12'd2000, 20);
        hold_code(12'd3000, 12);
        if (peak_events != 3)
            $fatal(1, "held pressure after reset produced a stale completion");
        hold_code(12'd2000, 12);
        expect_peak(2'd2, 12'd1000);
        hold_code(12'd3000, 12);
        if (peak_events != 4)
            $fatal(1, "post-reset released/armed target press did not complete");

        // ADC timeout cancels a held press; clear/enable cannot clear the fault.
        hold_code(12'd2000, 12);
        @(negedge adc_clk);
        suppress_eoc = 1;
        wait (sensor_fault === 1'b1);
        pulse_clear;
        @(negedge app_clk);
        enabled = 0;
        @(negedge app_clk);
        enabled = 1;
        @(negedge adc_clk);
        suppress_eoc = 0;
        hold_code(12'd3000, 12);
        hold_code(12'd1000, 12);
        hold_code(12'd3000, 12);
        if (sensor_fault !== 1 || peak_events != 4 ||
            dut.adc_fault_sticky !== 1)
            $fatal(1, "ADC fault was cleared or allowed subsequent counts");

        // Independent overflow cause: pause the application clock while ADC
        // sampling continues. A full mailbox drops samples and latches fault.
        common_reset;
        hold_code(12'd3000, 12);
        if (sensor_fault !== 0)
            $fatal(1, "common reset failed to clear hardware fault");
        dropped_before = dropped_samples;
        @(negedge app_clk);
        app_clock_running = 0;
        @(negedge adc_clk);
        analog_code = 12'd1000;
        wait (dut.overflow_sticky === 1'b1);
        repeat (3) @(negedge adc_clk);
        if (dropped_samples <= dropped_before || dut.adc_fault_sticky !== 0)
            $fatal(1, "mailbox overflow scenario did not isolate dropped samples");
        app_clock_running = 1;
        wait (sensor_fault === 1'b1);
        pulse_clear;
        hold_code(12'd1000, 12);
        hold_code(12'd3000, 12);
        if (sensor_fault !== 1 || peak_events != 4)
            $fatal(1, "overflow fault allowed counts or cleared with session");
        if (source_samples < 250 || filtered_samples < 200 ||
            expected_peak_count != peak_events)
            $fatal(1, "pipeline scenarios or scoreboard were not exercised");
        $display("PASS: tb_cpr_sensor_path adc_samples=%0d raw_samples=%0d filtered=%0d peaks=%0d dropped=%0d",
            source_samples, raw_samples, filtered_samples, peak_events,
            dropped_samples);
        $finish;
    end

    initial begin
        #30000000;
        $fatal(1, "tb_cpr_sensor_path global timeout");
    end
endmodule
