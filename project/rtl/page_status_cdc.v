// Coalesce rapidly changing status while a coherent mailbox transfer is busy.
// No event count is promised; the latest stable status is eventually delivered.
module page_status_cdc(
    input wire src_clk, src_rst_n,
    input wire [11:0] status,
    input wire dst_clk, dst_rst_n,
    output wire [11:0] video_status
);
reg sent;
reg [11:0] last_sent;
wire busy;
wire send = !busy && (!sent || status != last_sent);
always @(posedge src_clk or negedge src_rst_n) begin
    if (!src_rst_n) begin sent<=0; last_sent<=0; end
    else if (send) begin sent<=1; last_sent<=status; end
end
sample_mailbox u_transfer(
    .src_clk(src_clk), .src_rst_n(src_rst_n), .src_valid(send),
    .src_data(status), .src_busy(busy), .overflow_sticky(),
    .dst_clk(dst_clk), .dst_rst_n(dst_rst_n),
    .dst_valid(), .dst_data(video_status));
endmodule
