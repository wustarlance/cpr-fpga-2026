`timescale 1ns/1ps
module tb_sample_mailbox;
    reg src_clk = 0;
    reg dst_clk = 0;
    always #7 src_clk = ~src_clk;
    always #11 dst_clk = ~dst_clk;
    reg src_rst_n = 0;
    reg dst_rst_n = 0;
    reg src_valid = 0;
    reg [11:0] src_data = 0;
    wire src_busy, overflow_sticky, dst_valid;
    wire [11:0] dst_data;
    sample_mailbox dut (
        .src_clk(src_clk), .src_rst_n(src_rst_n), .src_valid(src_valid), .src_data(src_data),
        .src_busy(src_busy), .overflow_sticky(overflow_sticky),
        .dst_clk(dst_clk), .dst_rst_n(dst_rst_n), .dst_valid(dst_valid), .dst_data(dst_data));

    reg [11:0] queue [0:511];
    integer written = 0;
    integer read_count = 0;
    integer dropped = 0;
    integer i;
    reg expected_overflow = 0;
    reg [11:0] last_output = 0;
    reg previous_valid = 0;

    // Acceptance is tested before NBA updates, at the actual source edge.
    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            written = 0;
            dropped = 0;
            expected_overflow = 0;
        end else begin
            if (src_valid) begin
                if (src_busy) begin
                    expected_overflow = 1;
                    dropped = dropped + 1;
                end else begin
                    if (written >= 512) $fatal(1, "FAIL reference queue overflow");
                    queue[written] = src_data;
                    written = written + 1;
                end
            end
            #1;
            if (overflow_sticky !== expected_overflow)
                $fatal(1, "FAIL sticky overflow expected=%b actual=%b", expected_overflow, overflow_sticky);
        end
    end

    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            read_count = 0;
            last_output = 0;
            previous_valid = 0;
        end else begin
            #1;
            if (dst_valid !== 0 && dst_valid !== 1)
                $fatal(1, "FAIL unknown dst_valid");
            if (dst_valid) begin
                if (previous_valid) $fatal(1, "FAIL dst_valid exceeds one destination cycle");
                if (read_count >= written)
                    $fatal(1, "FAIL unexpected/duplicate destination event");
                if (dst_data !== queue[read_count])
                    $fatal(1, "FAIL word %0d expected=%0h actual=%0h", read_count, queue[read_count], dst_data);
                read_count = read_count + 1;
                last_output = dst_data;
            end else if (dst_data !== last_output) begin
                $fatal(1, "FAIL output changed while dst_valid low");
            end
            previous_valid = dst_valid;
        end
    end

    task pulse_source;
        input integer word;
        begin
            @(negedge src_clk); src_data = word; src_valid = 1;
            @(negedge src_clk); src_valid = 0;
        end
    endtask

    task wait_idle;
        integer cycles;
        begin
            cycles = 0;
            @(negedge src_clk);
            while (src_busy) begin
                @(negedge src_clk);
                cycles = cycles + 1;
                if (cycles > 40) $fatal(1, "FAIL acknowledgement timeout");
            end
        end
    endtask

    task check_drained;
        begin
            wait_idle();
            repeat (4) @(negedge dst_clk);
            if (read_count != written)
                $fatal(1, "FAIL accepted/delivered counts %0d/%0d", written, read_count);
            if (dst_valid !== 0) $fatal(1, "FAIL event on idle mailbox");
        end
    endtask

    task common_reset;
        begin
            // Common asynchronous assertion, then separate clock-aligned
            // release. The testbench release precedes each positive edge.
            src_valid = 0;
            src_rst_n = 0;
            dst_rst_n = 0;
            #1;
            if (src_busy !== 0 || overflow_sticky !== 0 || dst_valid !== 0 || dst_data !== 0)
                $fatal(1, "FAIL common asynchronous reset outputs");
            repeat (3) @(negedge src_clk);
            src_rst_n = 1;
            @(negedge dst_clk); dst_rst_n = 1;
            repeat (3) @(negedge dst_clk);
        end
    endtask

    initial begin
        repeat (3) @(negedge src_clk);
        src_rst_n = 1;
        @(negedge dst_clk); dst_rst_n = 1;
        repeat (6) @(negedge dst_clk);
        if (dst_valid !== 0 || written != 0 || read_count != 0)
            $fatal(1, "FAIL empty mailbox generated event");

        // Non-integer 14:22 clock-period ratio; each pulse is one source
        // cycle, and each coherent word must arrive once in order.
        pulse_source(0); wait_idle();
        pulse_source(4095); wait_idle();
        for (i = 0; i < 36; i = i + 1) begin
            pulse_source((i * 733 + 19) % 4096);
            wait_idle();
            repeat (i % 4) @(negedge src_clk);
        end
        check_drained();
        if (overflow_sticky !== 0 || dropped != 0 || written != 38)
            $fatal(1, "FAIL sparse transfer counts/sticky");

        // Overload without respecting busy: retained data must remain
        // coherent, rejected requests must not arrive, overflow is sticky.
        for (i = 0; i < 24; i = i + 1) pulse_source(1000 + i);
        check_drained();
        if (dropped == 0 || overflow_sticky !== 1)
            $fatal(1, "FAIL deliberate overload was not detected");
        $display("INFO tb_sample_mailbox before reset accepted=%0d delivered=%0d dropped=%0d", written, read_count, dropped);

        pulse_source(12'hABC);
        if (src_busy !== 1) $fatal(1, "FAIL request must be in flight before cancellation");
        common_reset();
        repeat (8) @(negedge dst_clk);
        if (written != 0 || read_count != 0 || overflow_sticky !== 0 || dst_valid !== 0)
            $fatal(1, "FAIL reset did not cancel in-flight request");
        pulse_source(12'h543); wait_idle();
        pulse_source(12'hAAA); wait_idle();
        check_drained();
        if (written != 2 || read_count != 2 || dropped != 0 || overflow_sticky !== 0)
            $fatal(1, "FAIL post-reset transfer accounting");
        $display("PASS tb_sample_mailbox post-reset accepted=%0d delivered=%0d", written, read_count);
        $finish;
    end

    initial begin
        #50000;
        $fatal(1, "TIMEOUT tb_sample_mailbox");
    end
endmodule
