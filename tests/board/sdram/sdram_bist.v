`timescale 1ns/1ps
// APUG011 ERAM-port diagnostic, not a replacement memory controller.
// Ordered, lossless read responses are required; no ready signal exists.
// Every burst starts at a four-word boundary and stays contiguous once begun.
module sdram_bist #(
    parameter integer ADDR_BITS = 21,
    parameter integer WORDS = 2097152,
    parameter integer RETENTION_CYCLES = 4000000, // 100 ms at the existing 40 MHz
    parameter integer GAP_CYCLES = 16,
    parameter integer IO_TIMEOUT_CYCLES = 40000,
    parameter integer INIT_TIMEOUT_CYCLES = 80000000
)(
    input wire clk, rst,
    input wire init_done, refresh_active,
    input wire short_burst, // stable before reset release: 0=256, 1=128 words
    output wire wr_en,
    output wire [ADDR_BITS-1:0] wr_addr,
    output wire [31:0] wr_data,
    output wire rd_en,
    output wire [ADDR_BITS-1:0] rd_addr,
    input wire rd_valid,
    input wire [31:0] rd_data,
    output reg [3:0] status, // 0 init,1 write,2 retention,3 read,4 pass,E data,F protocol
    output reg [1:0] phase,
    output reg [ADDR_BITS-1:0] first_bad_addr,
    output reg [31:0] first_expected, first_actual,
    output wire done,
    output reg [1:0] fault, // 0 none,1 data mismatch,2 timeout,3 response without request
    // Instrumentation for pattern 2 only: it is the first pattern whose words
    // differ, so a shifted or aliased access is invisible in patterns 0 and 1.
    // A one-word shift makes every word bad; an address alias makes half bad.
    output reg [31:0] head_map,        // bit k: word k of pattern 2, read one, matched
    output reg [31:0] mismatch_count,  // pattern 2, read one, mismatched words
    output reg [31:0] mismatch_count_2,// pattern 2, read two, mismatched words
    output reg [ADDR_BITS-1:0] last_bad_addr
);
    localparam WAIT_INIT=0, WRITE=1, WRITE_GAP=2, RETAIN=3,
               READ=4, DRAIN=5, READ_GAP=6, NEXT_PHASE=7, PASS=8, FAIL=9;
    reg [3:0] state;
    reg [ADDR_BITS:0] written, issued, received;
    reg [8:0] in_burst;
    reg [31:0] wait_count, watchdog;
    reg burst_short, read_repeat, data_error;
    wire [8:0] burst_last = burst_short ? 9'd127 : 9'd255;
    wire first_word_ready = (in_burst != 0) || !refresh_active;
    assign wr_en = !rst && init_done && state == WRITE && first_word_ready;
    assign rd_en = !rst && init_done && state == READ && first_word_ready;
    assign wr_addr = written[ADDR_BITS-1:0];
    assign rd_addr = issued[ADDR_BITS-1:0];
    assign done = (state == PASS || state == FAIL);

    function [31:0] pattern;
        input [1:0] p;
        input [ADDR_BITS-1:0] address;
        reg [20:0] a;
        begin
            a = address;
            case (p)
                0: pattern = 32'h00000000;
                1: pattern = 32'hffffffff;
                2: pattern = {a, ~a[10:0]} ^ 32'h5a3c96e1;
                3: pattern = ~({a, ~a[10:0]} ^ 32'h5a3c96e1);
            endcase
        end
    endfunction
    assign wr_data = pattern(phase, wr_addr);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= WAIT_INIT; status <= 0; phase <= 0;
            written <= 0; issued <= 0; received <= 0; in_burst <= 0;
            wait_count <= 0; watchdog <= 0; burst_short <= 0; read_repeat <= 0;
            first_bad_addr <= 0; first_expected <= 0; first_actual <= 0; fault <= 0;
            data_error <= 0; head_map <= 0; mismatch_count <= 0; mismatch_count_2 <= 0;
            last_bad_addr <= 0;
        end else if (!done) begin
            // Retention is deliberate inactivity. All other waits have a bound.
            if (wr_en || rd_en || rd_valid || state == RETAIN)
                watchdog <= 0;
            else watchdog <= watchdog + 1'b1;

            case (state)
                WAIT_INIT: if (init_done && !refresh_active) begin
                    burst_short <= short_burst; state <= WRITE; status <= 1;
                end
                WRITE: if (wr_en) begin
                    written <= written + 1'b1;
                    if (written == WORDS-1) begin
                        in_burst <= 0; wait_count <= 0; state <= RETAIN; status <= 2;
                    end else if (in_burst == burst_last) begin
                        in_burst <= 0; wait_count <= 0; state <= WRITE_GAP;
                    end else in_burst <= in_burst + 1'b1;
                end
                WRITE_GAP: if (wait_count == GAP_CYCLES-1) begin
                    wait_count <= 0; state <= WRITE;
                end else wait_count <= wait_count + 1'b1;
                RETAIN: if (wait_count == RETENTION_CYCLES-1) begin
                    wait_count <= 0; state <= READ; status <= 3;
                end else wait_count <= wait_count + 1'b1;
                READ: if (rd_en) begin
                    issued <= issued + 1'b1;
                    if (in_burst == burst_last || issued == WORDS-1) begin
                        in_burst <= 0; state <= DRAIN;
                    end else in_burst <= in_burst + 1'b1;
                end
                DRAIN: if (received == issued && issued != WORDS) begin
                    wait_count <= 0; state <= READ_GAP;
                end
                READ_GAP: if (wait_count == GAP_CYCLES-1) begin
                    wait_count <= 0; state <= READ;
                end else wait_count <= wait_count + 1'b1;
                NEXT_PHASE: begin
                    // A recorded mismatch ends the sweep, but only after the
                    // whole pattern ran, so the counts stay interpretable.
                    if (data_error) begin state <= FAIL; status <= 4'he; end
                    else if (phase == 3) begin state <= PASS; status <= 4; end
                    else begin
                        phase <= phase + 1'b1; written <= 0; issued <= 0; received <= 0;
                        read_repeat <= 0; in_burst <= 0; state <= WRITE; status <= 1;
                    end
                end
                default: begin state <= FAIL; status <= 4'hf; fault <= 3; end
            endcase

            if (rd_valid) begin
                if ((state != READ && state != DRAIN && state != READ_GAP) ||
                    received >= issued + rd_en || received >= WORDS) begin
                    state <= FAIL; status <= 4'hf; fault <= 3;
                    first_bad_addr <= received[ADDR_BITS-1:0];
                    first_expected <= pattern(phase, received[ADDR_BITS-1:0]);
                    first_actual <= rd_data;
                end else begin
                    // Record and keep sweeping instead of stopping at the first
                    // mismatch: one bad word is a single faulty cell, half of
                    // them is an address alias, all of them a pipeline shift.
                    if (rd_data !== pattern(phase, received[ADDR_BITS-1:0])) begin
                        if (!data_error) begin
                            data_error <= 1'b1; status <= 4'he; fault <= 1;
                            first_bad_addr <= received[ADDR_BITS-1:0];
                            first_expected <= pattern(phase, received[ADDR_BITS-1:0]);
                            first_actual <= rd_data;
                        end
                        last_bad_addr <= received[ADDR_BITS-1:0];
                        if (phase == 2) begin
                            if (!read_repeat)
                                mismatch_count <= (mismatch_count == 32'hffffffff) ?
                                    mismatch_count : mismatch_count + 32'd1;
                            else
                                mismatch_count_2 <= (mismatch_count_2 == 32'hffffffff) ?
                                    mismatch_count_2 : mismatch_count_2 + 32'd1;
                        end
                    end
                    if (phase == 2 && !read_repeat && !received[ADDR_BITS-1:5])
                        head_map[received[4:0]] <=
                            (rd_data === pattern(phase, received[ADDR_BITS-1:0]));
                    received <= received + 1'b1;
                    if (received == WORDS-1) begin
                        if (!read_repeat) begin
                            // A second read without rewriting catches changing readback.
                            read_repeat <= 1; issued <= 0; received <= 0;
                            wait_count <= 0; state <= READ_GAP;
                        end else state <= NEXT_PHASE;
                    end
                end
            end
            if (!wr_en && !rd_en && !rd_valid && state != RETAIN &&
                ((state == WAIT_INIT && watchdog == INIT_TIMEOUT_CYCLES-1) ||
                 (state != WAIT_INIT && watchdog == IO_TIMEOUT_CYCLES-1))) begin
                state <= FAIL;
                // Never overwrite an already characterised data error with the
                // timeout that a shifted read stream causes further downstream.
                if (!data_error) begin
                    status <= 4'hf; fault <= 2;
                    first_bad_addr <= received[ADDR_BITS-1:0];
                    first_expected <= pattern(phase, received[ADDR_BITS-1:0]);
                    first_actual <= 0;
                end
            end
        end
    end
endmodule
