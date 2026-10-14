// Board SW1..3 are independent asynchronous switches, filtered at tick_ms.
// Raw codes: 000 neutral, 001 0.50, 010 0.75, 011 1.25, 100 1.50;
// 101..111 return to neutral. SW4 remains available for the demo contacts.
// In the board-button training demo all dips describe contact depth, so hold
// the previous display setting during training. ADC/external-contact modes
// may continue using these switches because their pressure source is separate.
module contrast_controls #(
    parameter HOLD_DURING_TRAINING=1,
    parameter STABLE_MS=20
)(
    input wire clk,rst_n,tick_ms,
    input wire [2:0] raw_switches,
    input wire training_enabled,
    output reg [2:0] contrast_level
);
    wire [2:0] switches;
    input_filter #(.WIDTH(3),.STABLE_MS(STABLE_MS)) u_switches(
        .clk(clk),.rst_n(rst_n),.tick_ms(tick_ms),.raw(raw_switches),
        .level(switches),.rise());
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) contrast_level<=3'd2;
        else if(!HOLD_DURING_TRAINING || !training_enabled) begin
            case(switches)
                1:contrast_level<=3'd0;
                2:contrast_level<=3'd1;
                3:contrast_level<=3'd3;
                4:contrast_level<=3'd4;
                default:contrast_level<=3'd2;
            endcase
        end
    end
endmodule
