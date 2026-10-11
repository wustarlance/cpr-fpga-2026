// Per-channel RGB brightness, combinational and zero added pixel latency.
// level: 0=25%, 1=50%, 2=75%, 3=100%.
// Levels 0/1 truncate; level 2 computes x - floor(x/4).
// Place before cpr_overlay so status text retains its own colors.
module brightness_rgb(
    input wire [23:0] rgb,
    input wire [1:0] level,
    output wire [23:0] out_rgb
);
    function [7:0] scale_channel;
        input [7:0] value;
        input [1:0] setting;
        begin
            case (setting)
                0: scale_channel = {2'b0,value[7:2]};
                1: scale_channel = {1'b0,value[7:1]};
                2: scale_channel = value - {2'b0,value[7:2]};
                default: scale_channel = value;
            endcase
        end
    endfunction
    assign out_rgb = {scale_channel(rgb[23:16],level),
                      scale_channel(rgb[15:8],level),
                      scale_channel(rgb[7:0],level)};
endmodule
