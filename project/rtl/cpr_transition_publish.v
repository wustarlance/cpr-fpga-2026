// SD-clock publication bridge. Only tagged automatic page changes fade.
// The loader already holds its index until publish_done; keep that contract.
module cpr_transition_publish #(parameter integer GUARD_CYCLES=100_000_000)(
    input wire clk, rst,
    input wire publish_in, smooth_in, publish_done,
    input wire fade_ready_async,
    output reg fade_request,
    output reg publish_out
);
localparam IDLE=0, WAIT_BLACK=1, WAIT_DONE=2;
reg [1:0] state;
reg ready_meta, ready_sync;
reg [31:0] guard_count;
always @(posedge clk or posedge rst) begin
    if (rst) begin ready_meta<=0; ready_sync<=0; end
    else begin ready_meta<=fade_ready_async; ready_sync<=ready_meta; end
end
always @(posedge clk or posedge rst) begin
    if (rst) begin
        state<=IDLE; guard_count<=0; fade_request<=0; publish_out<=0;
    end else begin
        publish_out<=0;
        case (state)
            IDLE: begin
                guard_count<=0;
                if (publish_in) begin
                    if (smooth_in) begin fade_request<=1; state<=WAIT_BLACK; end
                    else begin publish_out<=1; state<=WAIT_DONE; end
                end
            end
            WAIT_BLACK: begin
                if (ready_sync || guard_count>=GUARD_CYCLES-1) begin
                    publish_out<=1; state<=WAIT_DONE;
                    // Missing VS must not deadlock page transport forever.
                    if (!ready_sync) fade_request<=0;
                end else guard_count<=guard_count+1'b1;
            end
            WAIT_DONE: if (publish_done) begin fade_request<=0; state<=IDLE; end
            default: begin state<=IDLE; fade_request<=0; end
        endcase
    end
end
endmodule
