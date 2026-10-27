`timescale 1ns/1ps
// level_percent 的档位→百分比对照（2026-10-27 亮度/对比度改百分比口径）。
//
// 期望值是"屏上应该看到的字"，直接写在下面这张表里，不从 DUT 反推：
//   亮度 4 档  : 25% / 50% / 75% / 100%
//   对比度 5 档: 0% / 25% / 50% / 75% / 100%
// 每一位用 4 位数字 + blank 掩码表示；blank=1 表示该格留空（前导零不画）。
module tb_level_percent;
    reg  [2:0] level;
    reg        is_contrast;
    wire [3:0] h, t, u;
    wire [2:0] blank;

    level_percent dut(.level(level), .is_contrast(is_contrast),
                      .hundreds(h), .tens(t), .units(u), .blank(blank));

    // {blank, hundreds, tens, units}
    reg [14:0] expect_bright [0:7];
    reg [14:0] expect_contrast [0:7];
    integer i, errors;

    initial begin
        // 亮度：只有 0..3 是合法档，5..7 按最低档 25% 显示（与 brightness_rgb 的
        // default 分支对应）。
        expect_bright[0] = {3'b100, 4'd0, 4'd2, 4'd5};   //  25%
        expect_bright[1] = {3'b100, 4'd0, 4'd5, 4'd0};   //  50%
        expect_bright[2] = {3'b100, 4'd0, 4'd7, 4'd5};   //  75%
        expect_bright[3] = {3'b000, 4'd1, 4'd0, 4'd0};   // 100%
        expect_bright[4] = {3'b100, 4'd0, 4'd2, 4'd5};
        expect_bright[5] = {3'b100, 4'd0, 4'd2, 4'd5};
        expect_bright[6] = {3'b100, 4'd0, 4'd2, 4'd5};
        expect_bright[7] = {3'b100, 4'd0, 4'd2, 4'd5};

        // 对比度：0..4 全部合法，5..7 回退 100%（contrast_rgb 的 default 分支）。
        expect_contrast[0] = {3'b110, 4'd0, 4'd0, 4'd0}; //   0%
        expect_contrast[1] = {3'b100, 4'd0, 4'd2, 4'd5}; //  25%
        expect_contrast[2] = {3'b100, 4'd0, 4'd5, 4'd0}; //  50%
        expect_contrast[3] = {3'b100, 4'd0, 4'd7, 4'd5}; //  75%
        expect_contrast[4] = {3'b000, 4'd1, 4'd0, 4'd0}; // 100%
        expect_contrast[5] = {3'b000, 4'd1, 4'd0, 4'd0};
        expect_contrast[6] = {3'b000, 4'd1, 4'd0, 4'd0};
        expect_contrast[7] = {3'b000, 4'd1, 4'd0, 4'd0};

        errors = 0;
        for (i = 0; i < 8; i = i + 1) begin
            level = i[2:0]; is_contrast = 1'b0; #1;
            if ({blank, h, t, u} !== expect_bright[i]) begin
                $display("FAIL brightness level=%0d got blank=%b h=%0d t=%0d u=%0d",
                         i, blank, h, t, u);
                errors = errors + 1;
            end
            is_contrast = 1'b1; #1;
            if ({blank, h, t, u} !== expect_contrast[i]) begin
                $display("FAIL contrast   level=%0d got blank=%b h=%0d t=%0d u=%0d",
                         i, blank, h, t, u);
                errors = errors + 1;
            end
        end
        if (errors == 0) $display("PASS: level_percent 2 x 8 levels match the percentage table");
        else $fatal(1, "level_percent errors=%0d", errors);
        $finish;
    end
endmodule
