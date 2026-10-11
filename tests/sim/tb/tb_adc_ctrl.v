`timescale 1ns / 1ps
module tb_adc_ctrl;
    reg clk = 1'b0;
    always #40.666667 clk = ~clk;
    reg rst_n = 1'b0;

    reg [11:0] fast_analog = 12'h251;
    reg [11:0] slow_analog = 12'h9a3;
    wire fast_soc, fast_pd, fast_valid, fast_fault;
    wire slow_soc, slow_pd, slow_valid, slow_fault;
    wire [2:0] fast_channel, slow_channel;
    wire [11:0] fast_data, slow_data;
    wire fast_model_eoc, slow_model_eoc;
    wire [11:0] fast_model_data, slow_model_data;
    reg suppress_fast_eoc = 1'b0;
    reg override_fast_eoc = 1'b0;
    reg injected_fast_eoc = 1'b0;
    wire fast_eoc = override_fast_eoc ? injected_fast_eoc :
        (suppress_fast_eoc ? 1'b0 : fast_model_eoc);

    adc_ctrl fast_dut (
        .clk(clk), .rst_n(rst_n), .adc_eoc(fast_eoc),
        .adc_dout(fast_model_data), .adc_soc(fast_soc), .adc_pd(fast_pd),
        .adc_channel(fast_channel), .sample_valid(fast_valid),
        .sample_data(fast_data), .fault(fast_fault)
    );
    adc_ctrl #(.SAMPLE_HZ(1000), .CHANNEL(4)) slow_dut (
        .clk(clk), .rst_n(rst_n), .adc_eoc(slow_model_eoc),
        .adc_dout(slow_model_data), .adc_soc(slow_soc), .adc_pd(slow_pd),
        .adc_channel(slow_channel), .sample_valid(slow_valid),
        .sample_data(slow_data), .fault(slow_fault)
    );
    eg_phy_adc_timing_model fast_model (
        .clk(clk), .pd(fast_pd), .s(fast_channel), .soc(fast_soc),
        .analog_code(fast_analog), .eoc(fast_model_eoc),
        .dout(fast_model_data)
    );
    eg_phy_adc_timing_model slow_model (
        .clk(clk), .pd(slow_pd), .s(slow_channel), .soc(slow_soc),
        .analog_code(slow_analog), .eoc(slow_model_eoc),
        .dout(slow_model_data)
    );

    // Zero sample rate must not create a divide-by-zero or any ADC request.
    wire invalid_soc, invalid_pd, invalid_valid, invalid_fault;
    wire [11:0] invalid_data;
    adc_ctrl #(.SAMPLE_HZ(0)) invalid_dut (
        .clk(clk), .rst_n(rst_n), .adc_eoc(1'b0), .adc_dout(12'hfff),
        .adc_soc(invalid_soc), .adc_pd(invalid_pd), .adc_channel(),
        .sample_valid(invalid_valid), .sample_data(invalid_data),
        .fault(invalid_fault)
    );

    integer cycle = 0;
    integer fast_samples = 0;
    integer slow_samples = 0;
    integer fast_socs = 0;
    integer fast_interval_checks = 0;
    integer slow_interval_checks = 0;
    integer fast_last_soc = 0;
    integer slow_last_soc = 0;
    integer fast_last_pd = 0;
    integer slow_last_pd = 0;
    integer fast_faults = 0;
    reg fast_check_cadence = 1'b1;
    reg fast_needs_priming_check = 1'b0;
    reg fast_prev_soc = 1'b0;
    reg slow_prev_soc = 1'b0;
    reg fast_prev_pd = 1'b0;
    reg slow_prev_pd = 1'b0;
    reg fast_prev_valid = 1'b0;
    reg slow_prev_valid = 1'b0;
    reg fast_prev_fault = 1'b0;
    reg fast_expected_pending = 1'b0;
    reg slow_expected_pending = 1'b0;
    reg [11:0] fast_expected;
    reg [11:0] slow_expected;
    reg [11:0] fast_last_data = 12'd0;
    reg [11:0] slow_last_data = 12'd0;

    // Sample the stimulus at the acquisition boundary, before the model's
    // nonblocking assignments. Inspect DUT results after NBA to avoid races.
    always @(posedge clk) begin
        cycle = cycle + 1;
        if (!rst_n || fast_pd)
            fast_expected_pending = 1'b0;
        else if (fast_model.counter == 4) begin
            fast_expected = fast_analog;
            fast_expected_pending = 1'b1;
        end
        if (!rst_n || slow_pd)
            slow_expected_pending = 1'b0;
        else if (slow_model.counter == 4) begin
            slow_expected = slow_analog;
            slow_expected_pending = 1'b1;
        end
        #1;
        if (!rst_n) begin
            if (fast_valid !== 0 || slow_valid !== 0 ||
                fast_soc !== 0 || slow_soc !== 0 ||
                fast_pd !== 1 || slow_pd !== 1)
                $fatal(1, "reset failed at cycle %0d", cycle);
            fast_last_soc = 0;
            slow_last_soc = 0;
            fast_prev_soc = 0;
            slow_prev_soc = 0;
            fast_prev_pd = 0;
            slow_prev_pd = 0;
            fast_prev_valid = 0;
            slow_prev_valid = 0;
            fast_prev_fault = 0;
            fast_needs_priming_check = 0;
            fast_last_data = 0;
            slow_last_data = 0;
        end else begin
            if ((^{fast_soc, fast_pd, fast_valid, fast_fault,
                    slow_soc, slow_pd, slow_valid, slow_fault}) === 1'bx)
                $fatal(1, "unknown control output at cycle %0d", cycle);
            if (fast_channel !== 3'd1 || slow_channel !== 3'd4)
                $fatal(1, "channel changed at cycle %0d", cycle);
            if ({invalid_soc, invalid_pd, invalid_valid, invalid_fault,
                    invalid_data} !== {1'b0, 1'b1, 1'b0, 1'b1, 12'd0})
                $fatal(1, "invalid parameter configuration was not safe");
            if ((fast_prev_soc && fast_soc) ||
                (slow_prev_soc && slow_soc) ||
                (fast_prev_valid && fast_valid) ||
                (slow_prev_valid && slow_valid) ||
                (fast_prev_fault && fast_fault))
                $fatal(1, "event pulse wider than one clock at cycle %0d", cycle);
            if (fast_pd && !fast_prev_pd) begin
                fast_last_pd = cycle;
                fast_needs_priming_check = 1;
            end
            if (slow_pd && !slow_prev_pd)
                slow_last_pd = cycle;
            if (fast_soc) begin
                if (fast_pd !== 0)
                    $fatal(1, "SOC asserted while PD high");
                if (fast_last_soc != 0 && fast_check_cadence) begin
                    if (cycle - fast_last_soc != 61)
                        $fatal(1, "fast SOC interval %0d, expected 61",
                            cycle - fast_last_soc);
                    fast_interval_checks = fast_interval_checks + 1;
                end
                if (fast_needs_priming_check) begin
                    if (cycle - fast_last_pd != 5)
                        $fatal(1, "fast priming offset %0d, expected 5",
                            cycle - fast_last_pd);
                    fast_needs_priming_check = 0;
                end
                fast_last_soc = cycle;
                fast_socs = fast_socs + 1;
            end
            if (slow_soc) begin
                if (slow_pd !== 0 || cycle - slow_last_pd != 5)
                    $fatal(1, "sparse PD placement failed at cycle %0d", cycle);
                if (slow_last_soc != 0) begin
                    if (cycle - slow_last_soc != 12295)
                        $fatal(1, "sparse SOC interval %0d, expected 12295",
                            cycle - slow_last_soc);
                    slow_interval_checks = slow_interval_checks + 1;
                end
                slow_last_soc = cycle;
            end
            if (fast_valid) begin
                if (!fast_expected_pending || fast_data !== fast_expected)
                    $fatal(1, "fast sample mismatch at %0d: got %h expected %h pending %b",
                        cycle, fast_data, fast_expected, fast_expected_pending);
                fast_expected_pending = 0;
                fast_samples = fast_samples + 1;
                fast_last_data = fast_data;
            end else if (fast_data !== fast_last_data)
                $fatal(1, "fast data changed without sample-valid at %0d", cycle);
            if (slow_valid) begin
                if (!slow_expected_pending || slow_data !== slow_expected)
                    $fatal(1, "sparse sample mismatch at %0d", cycle);
                slow_expected_pending = 0;
                slow_samples = slow_samples + 1;
                slow_last_data = slow_data;
            end else if (slow_data !== slow_last_data)
                $fatal(1, "sparse data changed without sample-valid at %0d", cycle);
            if (fast_fault)
                fast_faults = fast_faults + 1;
            if (slow_fault)
                $fatal(1, "unexpected sparse timeout at cycle %0d", cycle);
            fast_prev_soc = fast_soc;
            slow_prev_soc = slow_soc;
            fast_prev_pd = fast_pd;
            slow_prev_pd = slow_pd;
            fast_prev_valid = fast_valid;
            slow_prev_valid = slow_valid;
            fast_prev_fault = fast_fault;
        end
    end

    task tick;
        begin
            @(posedge clk);
            #2;
        end
    endtask

    // Exercise the model independently: acquiring late in the four-clock
    // window and changing the source before completion must return the former.
    reg model_pd = 1'b1;
    reg model_soc = 1'b0;
    reg [11:0] model_analog = 12'h111;
    wire model_eoc;
    wire [11:0] model_data;
    eg_phy_adc_timing_model independent_model (
        .clk(clk), .pd(model_pd), .s(3'd1), .soc(model_soc),
        .analog_code(model_analog), .eoc(model_eoc), .dout(model_data)
    );
    integer model_start_cycle;
    reg independent_model_done = 1'b0;
    initial begin
        tick;
        @(negedge clk);
        model_pd = 0;
        model_soc = 1;
        tick;
        model_start_cycle = cycle;
        if (independent_model.counter !== 5'd1 || model_eoc !== 0)
            $fatal(1, "model failed to accept SOC");
        @(negedge clk);
        model_soc = 0;
        model_analog = 12'h222;
        repeat (3) tick;
        if (independent_model.counter !== 5'd4)
            $fatal(1, "model acquisition boundary is wrong");
        @(negedge clk);
        model_analog = 12'habc;
        tick;
        @(negedge clk);
        model_analog = 12'hdef;
        model_soc = 1; // A second SOC during conversion must be ignored.
        tick;
        if (independent_model.counter !== 5'd6)
            $fatal(1, "busy model incorrectly restarted");
        @(negedge clk);
        model_soc = 0;
        @(posedge model_eoc);
        #2;
        if (model_data !== 12'habc || cycle - model_start_cycle != 16)
            $fatal(1, "model sample/completion mismatch: %h at interval %0d",
                model_data, cycle - model_start_cycle);
        tick;
        if (model_eoc !== 0)
            $fatal(1, "model EOC wider than one clock");
        @(negedge clk);
        model_soc = 1;
        tick;
        @(negedge clk);
        model_soc = 0;
        tick;
        #7;
        model_pd = 1;
        #1;
        if (model_eoc !== 0 || model_data !== 0 ||
                independent_model.counter !== 0)
            $fatal(1, "model PD did not clear asynchronously");
        @(negedge clk);
        model_pd = 0;
        repeat (20) begin
            tick;
            if (model_eoc !== 0)
                $fatal(1, "model emitted result after PD cancellation");
        end
        independent_model_done = 1;
    end

    integer started_cycle;
    integer fault_cycle;
    integer samples_before;
    integer socs_before;
    initial begin
        // An unsolicited/high EOC before startup must not become a sample.
        override_fast_eoc = 1;
        injected_fast_eoc = 1;
        repeat (3) tick;
        @(negedge clk);
        rst_n = 1;
        repeat (5) begin
            tick;
            if (fast_soc !== 0 || fast_valid !== 0)
                $fatal(1, "early startup request or unsolicited EOC accepted");
        end
        tick;
        if (fast_soc !== 1 || fast_valid !== 0)
            $fatal(1, "startup did not issue the sixth-edge SOC");
        @(negedge clk);
        override_fast_eoc = 0;
        injected_fast_eoc = 0;
        wait (fast_samples >= 8);
        @(negedge clk);
        if (fast_faults != 0)
            $fatal(1, "normal operation faulted");

        // Completion is EOC-driven, including a delayed completion at 30 clocks.
        suppress_fast_eoc = 1;
        @(posedge fast_soc);
        #2;
        started_cycle = cycle;
        samples_before = fast_samples;
        repeat (29) begin
            tick;
            if (fast_samples != samples_before)
                $fatal(1, "controller fabricated a fixed-latency completion");
        end
        @(negedge clk);
        override_fast_eoc = 1;
        injected_fast_eoc = 1;
        tick;
        if (cycle - started_cycle != 30 || fast_valid !== 1 ||
                fast_samples != samples_before + 1)
            $fatal(1, "delayed EOC was not accepted exactly once");
        @(negedge clk);
        override_fast_eoc = 0;
        injected_fast_eoc = 0;

        // Missing EOC: skip the busy 61-clock slot, then timeout at 64 clocks.
        fast_check_cadence = 0;
        @(posedge fast_soc);
        #2;
        started_cycle = cycle;
        samples_before = fast_samples;
        socs_before = fast_socs;
        repeat (63) begin
            tick;
            if (fast_fault !== 0 || fast_samples != samples_before ||
                    fast_socs != socs_before)
                $fatal(1, "busy conversion restarted or completed prematurely");
        end
        tick;
        fault_cycle = cycle;
        if (fast_fault !== 1 || fast_pd !== 1 ||
                fault_cycle - started_cycle != 64)
            $fatal(1, "timeout boundary failed");
        @(negedge clk);
        suppress_fast_eoc = 0;
        @(posedge fast_soc);
        #2;
        if (cycle - fault_cycle != 5)
            $fatal(1, "recovery did not prime for five clocks");
        @(posedge fast_valid);
        #2;
        if (fast_samples != samples_before + 1 || fast_faults != 1)
            $fatal(1, "timeout recovery duplicated or lost its new sample");

        // Reset during the next acquisition discards that transaction.
        @(posedge fast_soc);
        #2;
        repeat (4) tick;
        samples_before = fast_samples;
        @(negedge clk);
        rst_n = 0;
        repeat (3) tick;
        @(negedge clk);
        rst_n = 1;
        fast_check_cadence = 1;
        repeat (5) begin
            tick;
            if (fast_samples != samples_before || fast_soc !== 0)
                $fatal(1, "reset transaction leaked into startup");
        end
        tick;
        if (fast_soc !== 1)
            $fatal(1, "restart SOC missing");
        repeat (17) begin
            tick;
            if (fast_samples != samples_before)
                $fatal(1, "reset transaction produced a stale completion");
        end
        tick;
        if (fast_valid !== 1 || fast_samples != samples_before + 1)
            $fatal(1, "fresh post-reset conversion did not complete");
        wait (independent_model_done && slow_interval_checks >= 2 &&
            slow_samples >= 4);
        @(negedge clk);
        if (fast_interval_checks < 8 || fast_faults != 1)
            $fatal(1, "required fast scenarios did not execute");
        $display("PASS: tb_adc_ctrl fast_samples=%0d sparse_samples=%0d fast_intervals=%0d sparse_intervals=%0d timeouts=%0d",
            fast_samples, slow_samples, fast_interval_checks,
            slow_interval_checks, fast_faults);
        $finish;
    end

    initial begin
        #10000000;
        $fatal(1, "tb_adc_ctrl global timeout");
    end
endmodule
