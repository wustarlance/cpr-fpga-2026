// Single clock domain. tick_ms is a clock enable, never a generated clock.
module timebase #(parameter CLK_HZ = 50000000)(
    input wire clk,
    input wire rst_n,
    output reg tick_ms
);
    localparam DIV = CLK_HZ / 1000;
    reg [31:0] counter;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin counter <= 0; tick_ms <= 0; end
        else begin
            tick_ms <= 0;
            if (counter == DIV-1) begin counter <= 0; tick_ms <= 1; end
            else counter <= counter + 1'b1;
        end
    end
endmodule
