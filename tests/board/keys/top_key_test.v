`timescale 1ns/1ps
// 按键接线自检：外接八位面板 K1~K6 + 板载 KEY2/KEY3/KEY4。
// 与产品 top / top_adc 完全独立：只读按键，只驱动数码管和 LED，
// 构建产物是自己的 top_key_test.bit，不碰产品 bitstream。
//
// 面板模块（商品资料）：8 键 + VCC + GND 共 10 脚，内部带上拉，
//   按下输出低电平、松开输出高电平；VCC 必须接 J1 pin 29（3.3V）。
// 板载按键（开发板手册 ⑯ 4 组按键）：KEY1=A2 KEY2=B2 KEY3=B1 KEY4=C1，
//   按下为低电平。KEY1 是产品的复位脚，本测试不接。
//
// 显示约定（数码管左起）：
//   第 1~6 位：面板 K1~K6，按下显示 1~6，松开不亮
//   第 7 位  ：'A' = 板载 KEY4 按下（产品里这就是"切换模式"键）
//   第 8 位  ：'b' = KEY2 按下，'C' = KEY3 按下，'d' = 两个都按
//   LED1 = KEY2，LED2 = KEY3，LED3 = KEY4（亮 = 按下）
//   LED4 = 面板任意键按下
module top_key_test(
    input  wire       clk,
    input  wire [7:0] key_n,      // 面板 K1..K8，低电平 = 按下（K7/K8 只参与 LED4）
    input  wire [2:0] key_b_n,    // 板载 KEY2(B2) KEY3(B1) KEY4(C1)，低电平 = 按下
    output wire [7:0] seg_sel,
    output wire [7:0] seg_data,
    output wire [3:0] led
);
    // 上电复位：255 拍后释放，不依赖外部复位脚
    reg [7:0] por = 8'd0;
    always @(posedge clk) if (por != 8'hff) por <= por + 8'd1;
    wire rst_n = (por == 8'hff);

    // 两级同步，消除异步按键的亚稳态
    reg [7:0] key_meta, key_sync;
    reg [2:0] onb_meta, onb_sync;
    always @(posedge clk) begin
        key_meta <= key_n;
        key_sync <= key_meta;
        onb_meta <= key_b_n;
        onb_sync <= onb_meta;
    end

    // 约 1.3 ms 采样一次（50 MHz / 65536），相当于简单消抖
    reg [15:0] tick;
    always @(posedge clk) tick <= tick + 16'd1;
    reg [7:0] held;
    reg [2:0] onb_held;
    always @(posedge clk) if (tick == 16'hffff) begin
        held     <= key_sync;
        onb_held <= onb_sync;
    end

    wire [7:0] pressed     = ~held;       // 1 = 面板按下
    wire [2:0] onb_pressed = ~onb_held;   // 1 = 板载按下（[0]=KEY2 [1]=KEY3 [2]=KEY4）

    // 数字 1~6 与需要的几个十六进制字母字形
    wire [6:0] seg_one, seg_two, seg_three, seg_four, seg_five, seg_six;
    wire [6:0] seg_hex_a, seg_hex_b, seg_hex_c, seg_hex_d;
    seg_decoder u1(.bin_data(4'd1), .seg_data(seg_one));
    seg_decoder u2(.bin_data(4'd2), .seg_data(seg_two));
    seg_decoder u3(.bin_data(4'd3), .seg_data(seg_three));
    seg_decoder u4(.bin_data(4'd4), .seg_data(seg_four));
    seg_decoder u5(.bin_data(4'd5), .seg_data(seg_five));
    seg_decoder u6(.bin_data(4'd6), .seg_data(seg_six));
    seg_decoder ua(.bin_data(4'hA), .seg_data(seg_hex_a));   // 'A' KEY4
    seg_decoder ub(.bin_data(4'hB), .seg_data(seg_hex_b));   // 'b' KEY2
    seg_decoder uc(.bin_data(4'hC), .seg_data(seg_hex_c));   // 'C' KEY3
    seg_decoder ud(.bin_data(4'hD), .seg_data(seg_hex_d));   // 'd' 两个都按

    localparam [6:0] SEG_BLANK = 7'b111_1111;   // 共阳：全 1 = 全灭

    // 第 8 位：KEY2 / KEY3 的组合显示
    wire [6:0] seg_onb23 = (onb_pressed[0] && onb_pressed[1]) ? seg_hex_d :
                           onb_pressed[0] ? seg_hex_b :
                           onb_pressed[1] ? seg_hex_c : SEG_BLANK;

    cpr_seg_scan #(.CLK_FREQ(50_000_000)) u_scan(
        .clk      (clk),
        .rst_n    (rst_n),
        .seg_sel  (seg_sel),
        .seg_data (seg_data),
        .digit0   ({1'b1, pressed[0] ? seg_one   : SEG_BLANK}),
        .digit1   ({1'b1, pressed[1] ? seg_two   : SEG_BLANK}),
        .digit2   ({1'b1, pressed[2] ? seg_three : SEG_BLANK}),
        .digit3   ({1'b1, pressed[3] ? seg_four  : SEG_BLANK}),
        .digit4   ({1'b1, pressed[4] ? seg_five  : SEG_BLANK}),
        .digit5   ({1'b1, pressed[5] ? seg_six   : SEG_BLANK}),
        .digit6   ({1'b1, onb_pressed[2] ? seg_hex_a : SEG_BLANK}),
        .digit7   ({1'b1, seg_onb23})
    );

    // LED1/2/3 直接反映板载三键电平，LED4 反映面板是否有关按下的键
    assign led = {|pressed, onb_pressed};
endmodule
