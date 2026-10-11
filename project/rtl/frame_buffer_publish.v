`timescale 1ns/1ps
// Common reset: assertions simultaneous, releases synchronous in each domain.
// A completed buffer becomes active only at the reader's frame boundary.
module frame_buffer_publish (
    input wire src_clk, src_rst_n,
    input wire publish,
    input wire [1:0] buffer_index,
    output wire busy,
    output reg done,
    input wire mem_clk, mem_rst_n,
    input wire frame_start,
    output reg [1:0] active_index
);
    reg [1:0] held_index;
    reg request_toggle, ack_toggle;
    reg ack_meta, ack_sync, ack_seen;
    reg request_meta, request_sync;
    reg pending, pending_token, commit_pending;
    reg [1:0] pending_index;
    assign busy = request_toggle != ack_seen;
    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            held_index <= 0; request_toggle <= 0;
            ack_meta <= 0; ack_sync <= 0; ack_seen <= 0; done <= 0;
        end else begin
            ack_meta <= ack_toggle;
            ack_sync <= ack_meta;
            done <= 0;
            if (ack_sync != ack_seen) begin
                ack_seen <= ack_sync;
                done <= 1;
            end
            if (publish && !busy) begin
                held_index <= buffer_index;
                request_toggle <= ~request_toggle;
            end
        end
    end
    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            request_meta <= 0; request_sync <= 0; ack_toggle <= 0;
            pending <= 0; pending_token <= 0; pending_index <= 0;
            commit_pending <= 0; active_index <= 0;
        end else begin
            request_meta <= request_toggle;
            request_sync <= request_meta;
            if (commit_pending) begin
                // Reader captures active_index in S_ACK on this edge.
                ack_toggle <= pending_token;
                commit_pending <= 0;
            end else if (pending) begin
                if (frame_start) begin
                    active_index <= pending_index;
                    pending <= 0;
                    commit_pending <= 1;
                end
            end else if (request_sync != ack_toggle) begin
                pending_index <= held_index;
                pending_token <= request_sync;
                pending <= 1;
            end
        end
    end
endmodule
