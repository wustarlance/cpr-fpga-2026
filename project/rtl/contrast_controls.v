// 对比度来源：只剩外接面板的 K6 按键（相对步进）。
//
// 2026-10-26 改：**板载 SW1/SW2/SW3 不再参与对比度**。
//   原来这三位是"绝对选择"（000 中性，001 0.50，010 0.75，011 1.25，
//   100 1.50，101..111 回中性），拨到哪一档就是哪一档，并且按键一按就被
//   开关值每拍覆盖，所以还必须做一套"按键接管、开关变动才交还"的仲裁。
//   现在整块译码 + 仲裁都删掉了，原因：
//     * 这三位拨码的"拨上"到底是闭合还是断开，板卡资料里没有唯一结论
//       （见顶层 SW4 那段说明），同一个码在不同板上可能意义相反，现场
//       等于没法用；
//     * 对比度是"看着调"的参数，按键逐档步进比掰三个拨码直观，也不占
//       面板资源；SW1~3 腾出来后留给别的功能。
//
// 现在的语义（一路到底，没有仲裁）：
//   * 复位后 = 3'd3（100 %，恒等/直通）；
//   * 每按一次 K6 前进一档，3->4->5->1->2->3 循环，跳过0 %；
//     保留50/75/100/125/150 %，与现有OSD百分比显示一致。
//   * 训练模式下照样可调（对比度是显示参数，和训练状态无关）。
//
// 2026-10-27 改：档位含义由"增益 0.50…1.50"改成百分比口径，中性档落在第 3 档
// 100 %（0.50…1.50 那套的 100 % 其实落在第 2 档，屏上写 100 % 而画面不是原图，
// 讲解时容易误会）。同日再扩一档：0/50/75/100/125/150 %，既保留"0 % 全灰"
// 的演示档，也把被删掉的增强档（125 %/150 %）加回来。
// 2026-10-27 后续：移除0 %可选档，其他百分比与增益映射保持原样。
// 输出对比度档位给 contrast_rgb（做 RGB 乘法）和 cpr_overlay（OSD 里显示）。
module contrast_controls #(
    parameter STABLE_MS=20
)(
    input wire clk,rst_n,tick_ms,
    input wire raw_key,              // 对比度按键，高有效，内部消抖
    output reg [2:0] contrast_level
);
    // K6 消抖：只取"上升沿"，电平本身不用（按键是点动，不是开关）
    wire key_level, key_rise;
    input_filter #(.WIDTH(1),.STABLE_MS(STABLE_MS)) u_key(
        .clk(clk),.rst_n(rst_n),.tick_ms(tick_ms),.raw(raw_key),
        .level(key_level),.rise(key_rise));

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) contrast_level<=3'd3;
        else if(key_rise)
            contrast_level <= (contrast_level>=3'd5 || contrast_level==3'd0) ?
                              3'd1 : contrast_level + 3'd1;
    end
endmodule
