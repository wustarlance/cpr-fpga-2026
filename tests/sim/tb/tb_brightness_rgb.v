`timescale 1ns/1ps
// Exhaustively covers every 8-bit channel value at every brightness level.
// Channels deliberately differ to detect cross-channel wiring errors.
module tb_brightness_rgb;
    reg [23:0] rgb;
    reg [1:0] level;
    wire [23:0] out_rgb;
    reg [23:0] expected;
    integer setting, value, channel, raw_value, scaled_value;
    brightness_rgb dut(.rgb(rgb),.level(level),.out_rgb(out_rgb));
    initial begin
        rgb = 0; level = 0; expected = 0;
        for (setting = 0; setting < 4; setting = setting + 1) begin
            level = setting[1:0];
            for (value = 0; value < 256; value = value + 1) begin
                rgb = {value[7:0],(8'd255-value[7:0]),(value[7:0]^8'h5a)};
                for (channel = 0; channel < 3; channel = channel + 1) begin
                    raw_value = rgb[channel*8 +: 8];
                    case (setting)
                        0: scaled_value = raw_value / 4;
                        1: scaled_value = raw_value / 2;
                        2: scaled_value = raw_value - raw_value / 4;
                        default: scaled_value = raw_value;
                    endcase
                    expected[channel*8 +: 8] = scaled_value[7:0];
                end
                #1;
                if (out_rgb !== expected) begin
                    $display("FAIL setting=%0d rgb=%h actual=%h expected=%h",
                             setting,rgb,out_rgb,expected);
                    $fatal(1);
                end
            end
        end
        $display("PASS tb_brightness_rgb: 1024 RGB vectors, 3072 channel checks");
        $finish;
    end
    initial begin
        #2000;
        $fatal(1,"timeout");
    end
endmodule
