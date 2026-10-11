`timescale 1ns/1ps
// Bundled-data CDC mailbox: one coherent 12-bit word per accepted src_valid.
// Both resets must assert together; release each reset synchronously in its
// own domain. One-sided reset is not supported by this toggle protocol.
module sample_mailbox (
    input  wire        src_clk,
    input  wire        src_rst_n,
    input  wire        src_valid,
    input  wire [11:0] src_data,
    output wire        src_busy,
    output reg         overflow_sticky,
    input  wire        dst_clk,
    input  wire        dst_rst_n,
    output reg         dst_valid,
    output reg  [11:0] dst_data
);
    // Stable until destination capture has been acknowledged back to source.
    reg [11:0] src_hold;
    reg req_toggle;
    reg ack_toggle;
    reg ack_meta;
    reg ack_sync;
    reg req_meta;
    reg req_sync;
    reg capture_pending;
    reg pending_req;

    assign src_busy = (req_toggle != ack_sync);

    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            ack_meta <= 1'b0;
            ack_sync <= 1'b0;
        end else begin
            ack_meta <= ack_toggle;
            ack_sync <= ack_meta;
        end
    end

    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            src_hold <= 12'd0;
            req_toggle <= 1'b0;
            overflow_sticky <= 1'b0;
        end else if (src_valid) begin
            if (src_busy) begin
                overflow_sticky <= 1'b1;
            end else begin
                src_hold <= src_data;
                req_toggle <= ~req_toggle;
            end
        end
    end

    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            req_meta <= 1'b0;
            req_sync <= 1'b0;
        end else begin
            req_meta <= req_toggle;
            req_sync <= req_meta;
        end
    end

    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            dst_valid <= 1'b0;
            dst_data <= 12'd0;
            ack_toggle <= 1'b0;
            capture_pending <= 1'b0;
            pending_req <= 1'b0;
        end else begin
            dst_valid <= 1'b0;
            if (capture_pending) begin
                dst_data <= src_hold;
                dst_valid <= 1'b1;
                ack_toggle <= pending_req;
                capture_pending <= 1'b0;
            end else if (req_sync != ack_toggle) begin
                pending_req <= req_sync;
                capture_pending <= 1'b1;
            end
        end
    end
endmodule
