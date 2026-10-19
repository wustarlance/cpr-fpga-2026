`timescale 1ns/1ps
// Blank (erased) card sectors must not reach the screen as white pixels.
//
// A sector that was never written reads back as all-0xFF and its CRC is valid,
// so nothing upstream flags it; it simply becomes ~170 pure-white pixels.
// The loader now re-reads such a sector once. This test drives the real scaler
// with a synthetic 64x8 BMP and checks both outcomes:
//   phase 0: sector 2 is blank only on its first read -> retry clears it,
//            no white pixel may reach the frame buffer.
//   phase 1: sector 2 is blank every time -> white pixels appear, and the
//            persistent-blank instrument reports the sector.
module tb_sd_blank_sector;
    localparam integer W = 64, H = 8;
    localparam integer STRIDE = (W*3+3) & ~3;      // 192
    localparam integer DATA_BYTES = STRIDE*H;      // 1536
    localparam integer FILE_BYTES = 54 + DATA_BYTES;
    localparam integer BLANK_SECTOR = 2;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;                          // 100 MHz loader clock

    reg        pixel_ready = 1;
    reg        sd_sec_ready = 1;
    reg [31:0] sd_sec_read_addr = 0;
    reg [7:0]  sd_sec_read_data = 0;
    reg        sd_sec_read_data_valid = 0, sd_sec_read_end = 0;
    reg        write_req_ack = 0;
    reg        start_pulse = 0;

    wire        sd_sec_read_q;
    wire [31:0] sd_addr;
    wire        bmp_wr_en, dbg_ff_seen, load_error;
    wire [23:0] bmp_data;
    wire [20:0] dbg_ff_sector;
    wire [15:0] dbg_retry_count;
    wire [3:0]  state_code;

    bmp_read_scaled #(
        .DST_WIDTH(W), .DST_HEIGHT(H), .BLUR_BACKGROUND(0),
        .WAIT_TIMEOUT_CYCLES(400000)
    ) dut(
        .clk(clk), .rst(rst),
        .cancel(1'b0), .sd_sec_ready(sd_sec_ready), .sd_sec_read_error(1'b0),
        .abort_sd(), .operation_error(), .error_code(), .ready(),
        .scan_start(1'b0), .scan_start_sector(32'd0), .scan_max_sector(32'd8),
        .scan_target_count(3'd4), .scan_done(), .scan_found_valid(),
        .scan_found_sector(), .scan_found_total(),
        .load_start(start_pulse), .load_sector(32'd0), .sd_init_done(1'b1),
        .dbg_ff_sector(dbg_ff_sector), .dbg_ff_seen(dbg_ff_seen),
        .dbg_retry_count(dbg_retry_count), .state_code(state_code),
        .bmp_width(16'd0), .bmp_height(16'd0),
        .write_req(), .write_req_ack(write_req_ack),
        .sd_sec_read(sd_sec_read_q), .sd_sec_read_addr(sd_addr),
        .sd_sec_read_data(sd_sec_read_data),
        .sd_sec_read_data_valid(sd_sec_read_data_valid),
        .sd_sec_read_end(sd_sec_read_end),
        .bmp_data_wr_en(bmp_wr_en), .bmp_data(bmp_data),
        .pixel_ready(pixel_ready), .load_error(load_error)
    );

    // ---- synthetic card: little-endian BMP header + BGR rows ----
    function [7:0] file_byte;
        input integer n;
        integer row, col, v;
        begin
            if (n < 54) begin
                case (n)
                    0: file_byte = "B";  1: file_byte = "M";
                    2:  file_byte = FILE_BYTES;
                    3:  file_byte = FILE_BYTES >> 8;
                    10: file_byte = 54;
                    14: file_byte = 40;
                    18: file_byte = W;   20: file_byte = 0;
                    22: file_byte = H;   24: file_byte = 0;
                    26: file_byte = 1;   28: file_byte = 24;
                    default: file_byte = 8'd0;
                endcase
            end else begin
                row = (n - 54) / STRIDE;
                col = (n - 54) % STRIDE;
                if (col >= W*3) file_byte = 8'h00;
                else begin
                    v = (col/3) + row*3;               // never 0xFF
                    case (col % 3)
                        0: file_byte = v[6:0];
                        1: file_byte = 8'd64;
                        default: file_byte = v[6:0];
                    endcase
                end
            end
        end
    endfunction

    integer phase = 0;          // 0 = transient blank, 1 = persistent blank
    integer s2_reads = 0;       // times sector 2 was read in this phase
    integer n, sector, k;
    reg     blank_now;

    always begin
        @(negedge clk);
        if (!rst && sd_sec_read_q && !sd_sec_read_data_valid && !sd_sec_read_end) begin
            sector    = sd_addr;
            blank_now = (sector == BLANK_SECTOR) && ((phase == 1) || (s2_reads == 0));
            for (n = 0; n < 512; n = n + 1) begin
                sd_sec_read_data_valid <= 1'b1;
                if (blank_now) sd_sec_read_data <= 8'hff;
                else begin
                    k = sector*512 + n;
                    // Beyond EOF a real card holds whatever the writer left;
                    // use 0x00 so the tail does not look like an erased sector.
                    sd_sec_read_data <= (k < FILE_BYTES) ? file_byte(k) : 8'h00;
                end
                @(negedge clk);
            end
            sd_sec_read_data_valid <= 1'b0;
            sd_sec_read_end <= 1'b1;
            if (sector == BLANK_SECTOR) s2_reads = s2_reads + 1;
            @(negedge clk);
            sd_sec_read_end <= 1'b0;
        end
    end

    reg write_req_d = 0;
    always @(posedge clk) begin
        write_req_d <= dut.write_req;
        if (dut.write_req && !write_req_d) write_req_ack <= 1'b1;
        else if (!dut.write_req) write_req_ack <= 1'b0;
    end

    integer produced = 0, white = 0;
    always @(posedge clk) begin
        if (!rst && bmp_wr_en) begin
            produced = produced + 1;
            if (bmp_data == 24'hffffff) white = white + 1;
        end
    end

    task run_phase;
        input integer ph;
        begin
            phase = ph; s2_reads = 0;
            @(negedge clk); rst = 1;
            repeat(4) @(negedge clk);
            produced = 0; white = 0;
            rst = 0;
            repeat(4) @(negedge clk);
            @(negedge clk); start_pulse = 1;
            @(negedge clk); start_pulse = 0;
            repeat (W*H*30 + 30000) @(negedge clk);
            if (load_error) $fatal(1, "phase %0d: load reported an error", ph);
            if (produced != W*H)
                $fatal(1, "phase %0d: produced %0d pixels, expected %0d", ph, produced, W*H);
        end
    endtask

    initial begin
        // phase 0: transient blank, the re-read must clear it
        run_phase(0);
        if (dbg_retry_count != 16'd1)
            $fatal(1, "phase 0: expected exactly 1 sector re-read, saw %0d", dbg_retry_count);
        if (dbg_ff_seen)
            $fatal(1, "phase 0: transient blank wrongly reported as persistent");
        if (white != 0)
            $fatal(1, "phase 0: %0d white pixels escaped after the re-read", white);

        // phase 1: the sector is blank every time, so white is unavoidable
        run_phase(1);
        if (!dbg_ff_seen)
            $fatal(1, "phase 1: persistent blank was not reported");
        if (dbg_ff_sector != BLANK_SECTOR)
            $fatal(1, "phase 1: latched sector %0d, expected %0d", dbg_ff_sector, BLANK_SECTOR);
        if (white == 0)
            $fatal(1, "phase 1: no white pixels, mechanism not reproduced");

        $display("PASS: tb_sd_blank_sector re-read cleared the transient blank; persistent sector %0d yields %0d white pixels",
                 dbg_ff_sector, white);
        $finish;
    end
    initial begin #40000000; $fatal(1, "timeout phase=%0d produced=%0d", phase, produced); end
endmodule
