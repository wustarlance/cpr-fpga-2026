`timescale 1ns/1ps
module tb_rate_display_lut;
    reg [15:0] interval_ms = 0;
    reg rate_valid = 0;
    wire [7:0] bpm_approx;
    wire bpm_valid;
    integer errors = 0;
    integer ms, reference_bpm, previous_bpm;
    rate_display_lut dut (
        .interval_ms(interval_ms), .rate_valid(rate_valid),
        .bpm_approx(bpm_approx), .bpm_valid(bpm_valid)
    );
    initial begin
        interval_ms = 16'd545; #1;
        if (bpm_valid !== 0 || bpm_approx !== 0) begin
            $display("FAIL: no display before a valid measured interval");
            errors = errors + 1;
        end
        rate_valid = 1;
        previous_bpm = 120;
        // Exhaust every representable interval, including overflow/saturation.
        for (ms = 0; ms <= 65535; ms = ms + 1) begin
            interval_ms = ms; #1;
            if (ms >= 500 && ms <= 600) begin
                reference_bpm = (60000 + ms/2) / ms;
                if (bpm_valid !== 1 || bpm_approx < 100 || bpm_approx > 120 ||
                    bpm_approx > reference_bpm + 1 ||
                    bpm_approx + 1 < reference_bpm ||
                    bpm_approx > previous_bpm) begin
                    $display("FAIL: ms=%0d bpm=%0d ref=%0d valid=%b",
                             ms, bpm_approx, reference_bpm, bpm_valid);
                    errors = errors + 1;
                end
                previous_bpm = bpm_approx;
            end else if (bpm_valid !== 0 || bpm_approx !== 0) begin
                $display("FAIL: out-of-range interval %0d has a number", ms);
                errors = errors + 1;
            end
        end
        interval_ms = 500; #1;
        if (bpm_approx !== 120) errors = errors + 1;
        interval_ms = 600; #1;
        if (bpm_approx !== 100) errors = errors + 1;
        if (errors == 0) $display("PASS: rate_display_lut exhaustive range test");
        else $fatal(1, "rate_display_lut errors=%0d", errors);
        $finish;
    end
endmodule
