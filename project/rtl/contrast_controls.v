// 对比度来源：板载 SW1..3（绝对选择）与外接面板 K6 按键（相对步进）并存。
//
// 开关语义（原有，未改）：000 中性，001 0.50，010 0.75，011 1.25，100 1.50，
// 101..111 回中性。拨到某个码就直接等于该档位。
//
// 按键语义（新增）：每按一次 K6 前进一档，0->1->2->3->4->0 循环。按键按下后
// 由按键接管，直到开关再次变动才把控制权交还开关——否则开关值每拍都会把按键
// 的结果覆盖掉（这是本模块原先只有绝对译码、没有按键通路的原因）。
module contrast_controls #(
    parameter HOLD_DURING_TRAINING=1,
    parameter STABLE_MS=20
)(
    input wire clk,rst_n,tick_ms,
    input wire [2:0] raw_switches,
    input wire raw_key,              // 对比度按键，高有效，内部消抖
    input wire training_enabled,
    output reg [2:0] contrast_level
);
    wire [2:0] switches, switch_rise;
    input_filter #(.WIDTH(3),.STABLE_MS(STABLE_MS)) u_switches(
        .clk(clk),.rst_n(rst_n),.tick_ms(tick_ms),.raw(raw_switches),
        .level(switches),.rise(switch_rise));

    wire key_level, key_rise;
    input_filter #(.WIDTH(1),.STABLE_MS(STABLE_MS)) u_key(
        .clk(clk),.rst_n(rst_n),.tick_ms(tick_ms),.raw(raw_key),
        .level(key_level),.rise(key_rise));

    reg [2:0] decoded;
    always @(*) begin
        case(switches)
            1:decoded=3'd0;
            2:decoded=3'd1;
            3:decoded=3'd3;
            4:decoded=3'd4;
            default:decoded=3'd2;
        endcase
    end

    // 按键接管标志：任一开关出现上升沿即交还控制权
    reg key_override;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) key_override<=1'b0;
        else if(|switch_rise) key_override<=1'b0;
        else if(key_rise)     key_override<=1'b1;
    end

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) contrast_level<=3'd2;
        else if(key_rise)
            contrast_level <= (contrast_level==3'd4) ? 3'd0 : contrast_level + 3'd1;
        else if(!key_override && (!HOLD_DURING_TRAINING || !training_enabled))
            contrast_level <= decoded;
    end
endmodule
