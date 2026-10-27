// level_percent: 把亮度/对比度档位换算成百分比的三位十进制数字。
//
//   亮度 4 档（brightness_rgb）：level 0..3 → 25 / 50 / 75 / 100 %
//   对比度 6 档（contrast_rgb） ：level 0..5 →  0 / 50 / 75 / 100 / 125 / 150 %
//
// 只用常量表，不含除法器/乘法器，也没有 BCD 修正链：这些可能的百分比
// （0/25/50/75/100/125/150）每位都是常数，直接按档位查表即可。
//
// 输出是三位"分离的数字值"（每位 0..9）而不是打包 BCD，因为 OSD 里三个
// 数字固定占三个字符格、右对齐，前导零要留空；调用方按自己的字符编码
// 把数字映射成字形（中文界面 → 字库 ID，英文界面 → ASCII），'%' 由调用
// 方画在最后一格。这样两类 OSD 共用同一张百分比表，不会出现"中文显示
// 100%、英文显示 3"这种两套口径。
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
