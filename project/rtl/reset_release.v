// Raw reset asserts immediately; readiness crosses two clocks before release.
module reset_release(
    input wire clk,
    input wire reset_n_async,
    output wire rst_n,
    input wire ready
);

    reg ready_meta, ready_sync;
    reg [1:0] release_pipe;
    always @(posedge clk or negedge reset_n_async) begin
        if (!reset_n_async) begin
            ready_meta <= 0; ready_sync <= 0; release_pipe <= 0;
        end else begin
            ready_meta <= ready;
            ready_sync <= ready_meta;
            if (!ready_sync) release_pipe <= 0;
            else release_pipe <= {release_pipe[0],1'b1};
        end
    end
    assign rst_n = release_pipe[1];
endmodule
