`timescale 1ns/1ps
// 八位按键模块接线自检。与产品 top 完全独立：只读按键，点数码管和 LED。
//
// 模块特性（来自商品资料）：8 个独立按键 + VCC + GND 共 10 脚，
// 内部带上拉，按下输出低电平、松开输出高电平。
//
// 显示约定（数码管左起第 1~8 位对应 K1~K8）：
//   按下 Kk  →  第 k 位显示数字 k
//   松开     →  该位不亮
// LED 显示当前同时按下的按键个数的二进制，用于检查多键同时按下。
module top_key_test(
    input  wire       clk,
    input  wire [7:0] key_n,      // 模块 K1..K8，低电平 = 按下
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
    always @(posedge clk) begin
        key_meta <= key_n;
        key_sync <= key_meta;
    end

    // 约 1.3 ms 采样一次（50 MHz / 65536），相当于简单消抖
    reg [15:0] tick;
    always @(posedge clk) tick <= tick + 16'd1;
    reg [7:0] held;
    always @(posedge clk) if (tick == 16'hffff) held <= key_sync;

    wire [7:0] pressed = ~held;   // 1 = 按下

    // 每个按下位显示自己的编号：K1 -> '1' ... K8 -> '8'
    wire [6:0] seg_one, seg_two, seg_three, seg_four,
                seg_five, seg_six, seg_seven, seg_eight;
    seg_decoder u1(.bin_data(4'd1), .seg_data(seg_one));
    seg_decoder u2(.bin_data(4'd2), .seg_data(seg_two));
    seg_decoder u3(.bin_data(4'd3), .seg_data(seg_three));
    seg_decoder u4(.bin_data(4'd4), .seg_data(seg_four));
    seg_decoder u5(.bin_data(4'd5), .seg_data(seg_five));
    seg_decoder u6(.bin_data(4'd6), .seg_data(seg_six));
    seg_decoder u7(.bin_data(4'd7), .seg_data(seg_seven));
    seg_decoder u8(.bin_data(4'd8), .seg_data(seg_eight));

    localparam [6:0] SEG_BLANK = 7'b111_1111;   // 共阳：全 1 = 全灭

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
        .digit6   ({1'b1, pressed[6] ? seg_seven : SEG_BLANK}),
        .digit7   ({1'b1, pressed[7] ? seg_eight : SEG_BLANK})
    );

    // LED 显示同时按下的个数（0~8 的二进制）
    reg [3:0] count;
    integer i;
    always @(*) begin
        count = 4'd0;
        for (i = 0; i < 8; i = i + 1) count = count + pressed[i];
    end
    assign led = count;   // 板载 LED 实测高电平点亮
endmodule
