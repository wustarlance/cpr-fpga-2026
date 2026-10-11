// Asynchronous assertion, synchronous release in the application clock domain.
module reset_release(input wire clk, input wire reset_n_async, output wire rst_n);
    reg [1:0] release_pipe;
    always @(posedge clk or negedge reset_n_async) begin
        if (!reset_n_async) release_pipe <= 0;
        else release_pipe <= {release_pipe[0],1'b1};
    end
    assign rst_n = release_pipe[1];
endmodule
