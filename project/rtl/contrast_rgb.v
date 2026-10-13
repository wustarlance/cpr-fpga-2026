// contrast_rgb: per-channel RGB contrast adjustment. Combinational, zero
// added pixel latency, no clock/reset/pipe registers. The caller latches
// `level` at the frame boundary so it does not change mid-frame.
//
//   level | gain numerator | contrast multiplier
//   ------+----------------+--------------------
//     0   |       2        |       0.50
//     1   |       3        |       0.75
//     2   |       4        |       1.00 (identity)
//     3   |       5        |       1.25
//     4   |       6        |       1.50
//    5..7 |       4        |       1.00 (identity fallback)
//
// Per channel x (unsigned 8-bit):
//     t = floor(((x - 128) * gain) / 4) + 128
//     y = min(255, max(0, t))
//
// The floor division for negative operands is implemented with a signed
// arithmetic right shift (>>> 2), NOT integer division (which truncates
// toward zero). The signed negative intermediate is kept until saturation:
// the value is never pre-truncated to 8 bits, so there is no wrap, no X and
// no latch. The five constant gains use shift/add, not a multiplier.

module contrast_rgb(
    input  wire [23:0] rgb,      // R=[23:16] G=[15:8] B=[7:0]
    input  wire [2:0]  level,
    output wire [23:0] out_rgb
);

    function [7:0] contrast_channel;
        input [7:0] x;
        input [2:0] level;
        reg signed [15:0] diff;  // x - 128          : [-128, 127]
        reg signed [15:0] prod;  // diff * gain      : [-768, 762]
        reg signed [15:0] t;     // floor(prod/4)+128: [-64, 318]
        begin
            diff = $signed({1'b0, x}) - 16'sd128;
            case (level)
                3'd0:    prod = diff <<< 1;                   // *2
                3'd1:    prod = (diff <<< 1) + diff;          // *3
                3'd2:    prod = diff <<< 2;                   // *4
                3'd3:    prod = (diff <<< 2) + diff;          // *5
                3'd4:    prod = (diff <<< 2) + (diff <<< 1);  // *6
                default: prod = diff <<< 2;                   // *4 (5,6,7)
            endcase
            t = (prod >>> 2) + 16'sd128;                      // floor /4, +128
            if (t > 16'sd255)      t = 16'sd255;              // saturate high
            else if (t < 16'sd0)   t = 16'sd0;                // saturate low
            contrast_channel = t[7:0];
        end
    endfunction

    assign out_rgb = { contrast_channel(rgb[23:16], level),
                       contrast_channel(rgb[15:8],  level),
                       contrast_channel(rgb[7:0],   level) };

endmodule
