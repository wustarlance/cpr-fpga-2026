// Display-only rounded 60000 / interval_ms. The legacy module name is kept.
// A 17-cycle restoring divider avoids a combinational divider.
// Representable rates (235..65535 ms, 1..255 BPM) include slow/fast presses.
// training_core grading is independent and unchanged. Invalid inputs clear
// valid; valid updates hold the previous result until the new one is ready.
// Input changes restart calculation; reset/session clear cancels it.
module rate_display_lut (
    input wire clk, rst_n,
    input wire [15:0] interval_ms,
    input wire rate_valid,
    output reg [7:0] bpm_approx,
    output reg bpm_valid
);
    reg busy, have_interval;
    reg [15:0] denominator, remainder;
    reg [16:0] dividend;
    reg [4:0] remaining;
    wire input_valid = rate_valid && interval_ms >= 16'd235;
    wire [16:0] trial = {remainder, dividend[16]};
    wire subtract = trial >= {1'b0, denominator};
    wire [16:0] difference = trial - {1'b0, denominator};
    wire [16:0] next_dividend = {dividend[15:0], subtract};
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 0; have_interval <= 0; denominator <= 1;
            remainder <= 0; dividend <= 0; remaining <= 0;
            bpm_approx <= 0; bpm_valid <= 0;
        end else if (!input_valid) begin
            busy <= 0; have_interval <= 0; remaining <= 0;
            bpm_approx <= 0; bpm_valid <= 0;
        end else if (!have_interval || interval_ms != denominator) begin
            denominator <= interval_ms;
            dividend <= 17'd60000 + {2'b0, interval_ms[15:1]};
            remainder <= 0; remaining <= 17;
            busy <= 1; have_interval <= 1;
        end else if (busy) begin
            dividend <= next_dividend;
            remainder <= subtract ? difference[15:0] : trial[15:0];
            remaining <= remaining - 1'b1;
            if (remaining == 1) begin
                busy <= 0; bpm_approx <= next_dividend[7:0]; bpm_valid <= 1;
            end
        end
    end
endmodule
