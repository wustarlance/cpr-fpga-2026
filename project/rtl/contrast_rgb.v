// RGB 对比度组合运算，不增加像素延迟；调用方在帧边界锁存 level。
// level 0..5 对应 0/50/75/100/125/150%，6..7 回退到 100%。
// 0% 码保留在运算接口，按键控制不选择该档。
// 每通道 y=clamp(floor((x-128)*gain/4)+128, 0, 255)，gain 为 0/2/3/4/5/6。
// 负数使用算术右移向下取整，保留有符号中间值直至饱和；常量乘法由移位相加实现。

module contrast_rgb(
    input  wire [23:0] rgb,      // R=[23:16] G=[15:8] B=[7:0]
    input  wire [2:0]  level,
    output wire [23:0] out_rgb
);

    function [7:0] contrast_channel;
        input [7:0] x;
        input [2:0] level;
        reg signed [15:0] diff;  // x - 128          : [-128, 127]
        reg signed [15:0] prod;  // diff * gain      : [-512, 508]
        reg signed [15:0] t;     // floor(prod/4)+128
        begin
            diff = $signed({1'b0, x}) - 16'sd128;
            case (level)
                3'd0:    prod = 16'sd0;                       // *0 →   0 %
                3'd1:    prod = diff <<< 1;                   // *2 →  50 %
                3'd2:    prod = (diff <<< 1) + diff;          // *3 →  75 %
                3'd3:    prod = diff <<< 2;                   // *4 → 100 %
                3'd4:    prod = (diff <<< 2) + diff;          // *5 → 125 %
                3'd5:    prod = (diff <<< 2) + (diff <<< 1);  // *6 → 150 %
                default: prod = diff <<< 2;                   // *4 → 100 % (6,7)
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
