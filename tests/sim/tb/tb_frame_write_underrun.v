`timescale 1ns/1ps
// Does the write path ever push a word it was never given?
//
// The producer is deliberately hostile: it obeys write_ready but inserts random
// gaps and long stalls, which is what a slow BMP decoder looks like.  The SDRAM
// side must still receive exactly the supplied pixels, in order, once each.
// Reading the asynchronous write FIFO while it is empty repeats its last word,
// so a single over-read shows up immediately as a duplicated pixel.
module tb_frame_write_underrun;
    localparam integer FW = 160, FH = 4, TOTAL = FW*FH;

    reg mem_clk=0, write_clk=0, read_clk=0, rst=1;
    always #12.5 mem_clk=~mem_clk;   // 40 MHz memory
    always #5    write_clk=~write_clk; // 100 MHz producer
    always #20   read_clk=~read_clk;   // 25 MHz display (idle here)

    reg write_req=0, write_en=0, read_req=0;
    reg [31:0] write_data=0;
    wire write_ack, write_finish, write_ready, read_ack;
    wire wr_en, rd_en;
    wire [20:0] wr_addr, rd_addr;
    wire [31:0] wr_data, read_data;
    wire [3:0] dm;

    frame_read_write #(.FRAME_WIDTH(FW), .FRAME_HEIGHT(FH), .READ_INDEX_SYNCHRONOUS(1)) dut(
        .rst(rst), .mem_clk(mem_clk), .Sdr_init_done(!rst), .Sdr_init_ref_vld(1'b0), .Sdr_busy(1'b0),
        .App_wr_en(wr_en), .App_wr_addr(wr_addr), .App_wr_din(wr_data), .App_wr_dm(dm),
        .App_rd_en(rd_en), .App_rd_addr(rd_addr), .Sdr_rd_en(1'b0), .Sdr_rd_dout(32'd0),
        .write_clk(write_clk), .write_req(write_req), .write_req_ack(write_ack),
        .write_finish(write_finish),
        .write_addr_0(21'd0), .write_addr_1(21'd640), .write_addr_2(21'd1280),
        .write_addr_3(21'd1920), .write_addr_index(2'd0),
        .write_len(21'd640), .write_en(write_en), .write_data(write_data), .write_ready(write_ready),
        .read_clk(read_clk), .read_req(read_req), .read_req_ack(read_ack), .read_finish(),
        .read_addr_0(21'd0), .read_addr_1(21'd640), .read_addr_2(21'd1280),
        .read_addr_3(21'd1920), .read_addr_index(2'd0), .read_len(21'd640),
        .read_en(1'b0), .read_data(read_data), .frame_start());

    function [31:0] oracle;
        input integer n;
        begin oracle = 32'hC0DE0000 ^ (n * 32'h00010307); end
    endfunction

    integer supplied=0, written=0, gaps=0, underruns=0, stalls=0, done_time=0;
    reg [15:0] lfsr = 16'hace1;
    reg stalled = 0, started = 0;
    integer i;

    // The producer: random 30% gaps, plus a long dry spell after every 200 pixels.
    always @(negedge write_clk) begin
        lfsr <= {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
    end
    always @(negedge write_clk) begin
        if (rst) begin
            write_en <= 0; write_data <= 0; supplied = 0;
        end else if (started && supplied < TOTAL && !stalled) begin
            if (write_ready && lfsr[3:0] > 4) begin
                write_en <= 1'b1; write_data <= oracle(supplied);
                supplied = supplied + 1;
                if (supplied % 200 == 0) stalled <= 1;
            end else begin
                write_en <= 1'b0; gaps = gaps + 1;
            end
        end else begin
            write_en <= 1'b0;
            if (stalled) stalls = stalls + 1;
        end
    end

    // Release the long stall only once the producer's queue has drained.
    integer dry = 0;
    always @(negedge write_clk) begin
        if (stalled) begin
            dry = dry + 1;
            if (dry > 400) begin stalled <= 0; dry = 0; end
        end else dry = 0;
    end

    // Every word presented to the SDRAM must be the next supplied pixel.
    always @(posedge mem_clk) begin
        if (rst) begin written = 0; underruns = 0; end
        else if (wr_en) begin
            if (dut.write_buf.empty_flag) begin
                underruns = underruns + 1;
                $display("UNDERRUN at word %0d: FIFO empty, dout=%h", written, wr_data);
            end
            if (wr_data !== oracle(written))
                $fatal(1, "word %0d carries %h but producer supplied %h (duplicate or skip)",
                       written, wr_data, oracle(written));
            if (dm !== 4'b0000) $fatal(1, "byte mask not all-enabled at word %0d", written);
            written = written + 1;
            if (written == TOTAL) done_time = $time;
        end
    end

    initial begin
        repeat(8) @(negedge write_clk); rst = 0;
        @(negedge write_clk); write_req = 1;
        wait(write_ack); @(negedge write_clk); write_req = 0;
        wait(!write_ack);
        repeat(4) @(negedge write_clk);
        started = 1;
        // Completion signalling is not what this test is about; settle instead.
        while (written < TOTAL) @(negedge write_clk);
        repeat(200) @(negedge write_clk);
        if (supplied != TOTAL) $fatal(1, "producer supplied %0d of %0d", supplied, TOTAL);
        if (written != TOTAL) $fatal(1, "SDRAM saw %0d writes for %0d pixels", written, TOTAL);
        if (gaps == 0) $fatal(1, "producer never backed off, nothing was exercised");
        $display("PASS: tb_frame_write_underrun %0d pixels exact under %0d gap cycles and %0d dry cycles",
                 written, gaps, stalls);
        $finish;
    end
    initial begin #2000000;
        $fatal(1, "timeout supplied=%0d written=%0d done_at=%0d state=%0d write_cnt=%0d len=%0d burst_cnt=%0d into=%b fin=%b",
            supplied, written, done_time, dut.frame_fifo_write_m0.state,
            dut.frame_fifo_write_m0.write_cnt, dut.frame_fifo_write_m0.write_len_latch,
            dut.frame_fifo_write_m0.burst_cnt, dut.frame_fifo_write_m0.into_burst, write_finish);
    end
endmodule
