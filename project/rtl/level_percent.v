// 亮度和对比度档位查表，输出三个独立十进制数字及前导空白标志。
// 亮度 level 0..3 为 25/50/75/100%；对比度 level 0..5 为 0/50/75/100/125/150%。
// 调用方将数字转成中英文字形，并另画百分号；按键控制跳过对比度 0%。
module level_percent(
    input  wire [2:0] level,
    input  wire       is_contrast,   // 0 = 亮度，1 = 对比度
    output reg  [3:0] hundreds,      // 百位 0..9
    output reg  [3:0] tens,          // 十位 0..9
    output reg  [3:0] units,         // 个位 0..9
    output reg  [2:0] blank          // [2]=百位 [1]=十位 [0]=个位；1 = 该位留空
);
    always @(*) begin
        hundreds = 4'd0;
        tens     = 4'd0;
        units    = 4'd0;
        blank    = 3'b100;                       // 缺省：两位数字（25/50/75）
        if (!is_contrast) begin
            case (level)
                3'd0: begin tens = 4'd2; units = 4'd5; end                  // 25 %
                3'd1: begin tens = 4'd5; units = 4'd0; end                  // 50 %
                3'd2: begin tens = 4'd7; units = 4'd5; end                  // 75 %
                3'd3: begin hundreds = 4'd1; blank = 3'b000; end            // 100 %
                // 亮度只有 0..3 四档；5..7 是非法值，按最低档 25 % 显示，
                // 与 brightness_rgb 对这些码的处理（走 default 分支）保持显式区分。
                default: begin tens = 4'd2; units = 4'd5; end               // 25 %
            endcase
        end else begin
            case (level)
                3'd0: begin units = 4'd0; blank = 3'b110; end               //   0 %
                3'd1: begin tens = 4'd5; units = 4'd0; end                  //  50 %
                3'd2: begin tens = 4'd7; units = 4'd5; end                  //  75 %
                3'd3: begin hundreds = 4'd1; blank = 3'b000; end            // 100 %
                3'd4: begin hundreds = 4'd1; tens = 4'd2; units = 4'd5;
                             blank = 3'b000; end                        // 125 %
                3'd5: begin hundreds = 4'd1; tens = 4'd5; units = 4'd0;
                             blank = 3'b000; end                        // 150 %
                // 6..7 与 contrast_rgb 的 default 一致：按 100 %（直通）显示。
                default: begin hundreds = 4'd1; blank = 3'b000; end         // 100 %
            endcase
        end
    end
endmodule
