// K6 消抖后逐档调节对比度，所有模式共用。
// 复位档 3 对应 100%；循环顺序 3->4->5->1->2->3，跳过 0%。
// 档位同时送往 contrast_rgb 和 OSD；拨码不参与调节。
module contrast_controls #(
    parameter STABLE_MS=20
)(
    input wire clk,rst_n,tick_ms,
    input wire raw_key,              // 对比度按键，高有效，内部消抖
    output reg [2:0] contrast_level
);
    // 仅使用消抖后的按下沿。
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
