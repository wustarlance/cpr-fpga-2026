// Display-only approximation of 60000 / interval_ms. No RTL division.
// The 16 ROM entries cover the target range only (500..600 ms, inclusive).
// Outside that range, keep bpm_valid low and use rate_grade for fast/slow.
// Error versus the rounded exact integer rate in this range is <= 1 bpm.
module rate_display_lut (
    input wire [15:0] interval_ms, // 来自 training_core
    input wire rate_valid,         // 间隔是否有效
    output reg [7:0] bpm_approx,   // 近似 BPM（reg：在 always 里赋值）
    output wire bpm_valid          // wire：纯 assign
);
    reg [3:0] index;
    assign bpm_valid = rate_valid && interval_ms >= 16'd500 &&
                       interval_ms <= 16'd600;
    always @(*) begin
        if      (interval_ms <= 16'd503) index = 4'd0;
        else if (interval_ms <= 16'd510) index = 4'd1;
        else if (interval_ms <= 16'd517) index = 4'd2;
        else if (interval_ms <= 16'd524) index = 4'd3;
        else if (interval_ms <= 16'd531) index = 4'd4;
        else if (interval_ms <= 16'd538) index = 4'd5;
        else if (interval_ms <= 16'd545) index = 4'd6;
        else if (interval_ms <= 16'd552) index = 4'd7;
        else if (interval_ms <= 16'd559) index = 4'd8;
        else if (interval_ms <= 16'd566) index = 4'd9;
        else if (interval_ms <= 16'd573) index = 4'd10;
        else if (interval_ms <= 16'd580) index = 4'd11;
        else if (interval_ms <= 16'd587) index = 4'd12;
        else if (interval_ms <= 16'd594) index = 4'd13;
        else if (interval_ms <= 16'd599) index = 4'd14;
        else                            index = 4'd15;
        bpm_approx = 8'd0;
        if (bpm_valid) begin
            case (index)
                4'd0:  bpm_approx = 8'd120;
                4'd1:  bpm_approx = 8'd118;
                4'd2:  bpm_approx = 8'd117;
                4'd3:  bpm_approx = 8'd115;
                4'd4:  bpm_approx = 8'd114;
                4'd5:  bpm_approx = 8'd112;
                4'd6:  bpm_approx = 8'd111;
                4'd7:  bpm_approx = 8'd109;
                4'd8:  bpm_approx = 8'd108;
                4'd9:  bpm_approx = 8'd107;
                4'd10: bpm_approx = 8'd105;
                4'd11: bpm_approx = 8'd104;
                4'd12: bpm_approx = 8'd103;
                4'd13: bpm_approx = 8'd102;
                4'd14: bpm_approx = 8'd101;
                4'd15: bpm_approx = 8'd100;
            endcase
        end
    end
endmodule
