// Normalize polarity before this module. Output 1 means asserted.
// Independent switches are filtered independently; coherent buses need a handshake.
//
// 复位释放后的第一个 tick 只把当前电平取作基线，不产生上升沿：
// 否则上电瞬间已经处于"按下"电平的输入会被当成一次真实按键。某一路被
// 一直拉低（模块没供电、上拉缺失、线接错）时，主模式会每上电一次自动跳
// 一级，表现为"一开机就是训练模式，再按又按不动那种"。基线对齐之后，
// 这类输入只会如实保持它读到的状态，不会伪造按键事件。
module input_filter #(parameter WIDTH = 4, parameter STABLE_MS = 10)(
    input wire clk,
    input wire rst_n,
    input wire tick_ms,
    input wire [WIDTH-1:0] raw,
    output reg [WIDTH-1:0] level,
    output reg [WIDTH-1:0] rise
);
    reg [WIDTH-1:0] sync_a, sync_b;
    reg [15:0] stable_count [0:WIDTH-1];
    reg primed;
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync_a <= 0; sync_b <= 0; level <= 0; rise <= 0; primed <= 1'b0;
            for (i=0; i<WIDTH; i=i+1) stable_count[i] <= 0;
        end else begin
            sync_a <= raw; sync_b <= sync_a; rise <= 0;
            if (tick_ms) begin
                if (!primed) begin
                    level <= sync_b;
                    primed <= 1'b1;
                    for (i=0; i<WIDTH; i=i+1) stable_count[i] <= 0;
                end else begin
                    for (i=0; i<WIDTH; i=i+1) begin
                        if (sync_b[i] == level[i]) stable_count[i] <= 0;
                        else if (stable_count[i] == STABLE_MS-1) begin
                            level[i] <= sync_b[i]; rise[i] <= sync_b[i];
                            stable_count[i] <= 0;
                        end else stable_count[i] <= stable_count[i] + 1'b1;
                    end
                end
            end
        end
    end
endmodule
