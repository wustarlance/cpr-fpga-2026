// Single-frame reader fade-through-black. RGB gain changes only at VS falling.
// 16 steps each way, about 0.53 s plus the existing frame publication latency.
// The frame publisher cannot switch until ready; request stays high until ACK.
module cpr_slide_fade(
    input wire clk, rst, request_async,
    input wire vs, de,
    input wire [23:0] rgb,
    output wire ready,
    output reg out_vs, out_de,
    output reg [23:0] out_rgb,
    output reg [4:0] gain
);
reg request_meta, request_sync, last_vs;
reg vs_q, de_q;
reg [12:0] red_q, green_q, blue_q;
assign ready=request_sync && gain==0;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        request_meta<=0; request_sync<=0; last_vs<=1; gain<=16;
    end else begin
        request_meta<=request_async; request_sync<=request_meta; last_vs<=vs;
        if (last_vs && !vs) begin
            if (request_sync) begin if (gain!=0) gain<=gain-1'b1; end
            else if (gain<16) gain<=gain+1'b1;
        end
    end
end
always @(posedge clk or posedge rst) begin
    if (rst) begin
        red_q<=0; green_q<=0; blue_q<=0; vs_q<=1; de_q<=0;
        out_vs<=1; out_de<=0; out_rgb<=0;
    end else begin
        // Small constant-width products are isolated by pixel registers.
        red_q<=rgb[23:16]*gain;
        green_q<=rgb[15:8]*gain;
        blue_q<=rgb[7:0]*gain;
        vs_q<=vs; de_q<=de;
        out_rgb<={red_q[11:4],green_q[11:4],blue_q[11:4]};
        out_vs<=vs_q; out_de<=de_q;
    end
end
endmodule
