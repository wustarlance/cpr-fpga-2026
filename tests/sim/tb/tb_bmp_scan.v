`timescale 1ns/1ps

// Model the SD reader at its public byte/sector interface. The scoreboard
// checks observable requests and catalog events, independently of FSM states.
module tb_bmp_scan;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;
    wire ready;
    reg scan_start = 1'b0;
    reg [31:0] scan_start_sector = 0;
    reg [31:0] scan_max_sector = 0;
    reg [2:0] scan_target_count = 4;
    wire scan_done, scan_found_valid;
    wire [31:0] scan_found_sector;
    wire [2:0] scan_found_total;
    reg load_start = 1'b0;
    reg [31:0] load_sector = 0;
    reg sd_init_done = 1'b0;
    wire [3:0] state_code;
    wire write_req;
    reg write_req_ack = 1'b0;
    wire sd_sec_read;
    wire [31:0] sd_sec_read_addr;
    reg [7:0] sd_sec_read_data = 0;
    reg sd_sec_read_data_valid = 1'b0;
    reg sd_sec_read_end = 1'b0;
    wire bmp_data_wr_en;
    wire [23:0] bmp_data;

    bmp_read dut (
        .clk(clk), .rst(rst), .ready(ready),
        .scan_start(scan_start), .scan_start_sector(scan_start_sector),
        .scan_max_sector(scan_max_sector), .scan_target_count(scan_target_count),
        .scan_done(scan_done), .scan_found_valid(scan_found_valid),
        .scan_found_sector(scan_found_sector), .scan_found_total(scan_found_total),
        .load_start(load_start), .load_sector(load_sector),
        .sd_init_done(sd_init_done), .state_code(state_code),
        .bmp_width(16'd640), .bmp_height(16'd480),
        .write_req(write_req), .write_req_ack(write_req_ack),
        .sd_sec_read(sd_sec_read), .sd_sec_read_addr(sd_sec_read_addr),
        .sd_sec_read_data(sd_sec_read_data),
        .sd_sec_read_data_valid(sd_sec_read_data_valid),
        .sd_sec_read_end(sd_sec_read_end),
        .bmp_data_wr_en(bmp_data_wr_en), .bmp_data(bmp_data)
    );

    integer expected_found_count = 0;
    integer observed_found_count = 0;
    reg [31:0] expected_found_sector [0:7];
    reg catalog_check = 1'b0;
    reg pixel_check = 1'b0;
    integer pixel_count = 0;
    reg [23:0] expected_pixel;
    reg [7:0] expected_b, expected_g, expected_r;

    always @(posedge clk) begin
        #1;
        if (!rst && catalog_check && scan_found_valid) begin
            if (observed_found_count >= expected_found_count)
                $fatal(1, "[FAIL] unexpected catalog event at sector %0d", scan_found_sector);
            if (scan_found_sector !== expected_found_sector[observed_found_count])
                $fatal(1, "[FAIL] catalog sector %0d, expected %0d",
                       scan_found_sector, expected_found_sector[observed_found_count]);
            observed_found_count = observed_found_count + 1;
            if (scan_found_total !== observed_found_count)
                $fatal(1, "[FAIL] incorrect running catalog total");
        end
        if (!rst && pixel_check && bmp_data_wr_en) begin
            expected_b = (pixel_count * 3) & 255;
            expected_g = (pixel_count * 3 + 1) & 255;
            expected_r = (pixel_count * 3 + 2) & 255;
            expected_pixel = {expected_r, expected_g, expected_b};
            if (bmp_data !== expected_pixel)
                $fatal(1, "[FAIL] pixel %0d = %h, expected %h",
                       pixel_count, bmp_data, expected_pixel);
            pixel_count = pixel_count + 1;
        end
    end

    // profile: 0=not BMP, 1=valid, 2=wrong width, 3=wrong bpp,
    // 4=compressed. Payload bytes form known little-endian BGR pixels.
    function [7:0] file_byte;
        input integer position;
        input integer profile;
        input [31:0] length;
        reg [31:0] test_width;
        begin
            test_width = (profile == 2) ? 32'd320 : 32'd640;
            file_byte = 0;
            if (position >= 54)
                file_byte = (position - 54) & 255;
            else begin
                case (position)
                    0: file_byte = (profile == 0) ? 8'h00 : "B";
                    1: file_byte = (profile == 0) ? 8'h00 : "M";
                    2: file_byte = length[7:0];
                    3: file_byte = length[15:8];
                    4: file_byte = length[23:16];
                    5: file_byte = length[31:24];
                    10: file_byte = 54;
                    14: file_byte = 40;
                    18: file_byte = test_width[7:0];
                    19: file_byte = test_width[15:8];
                    22: file_byte = 8'he0;
                    23: file_byte = 8'h01;
                    26: file_byte = 1;
                    28: file_byte = (profile == 3) ? 16 : 24;
                    30: file_byte = (profile == 4) ? 1 : 0;
                    default: file_byte = 0;
                endcase
            end
        end
    endfunction

    task serve_sector;
        input [31:0] expected_address;
        input integer profile;
        input [31:0] length;
        input integer file_byte_base;
        input integer end_gap;
        input integer insert_gaps;
        integer i, timeout;
        begin
            timeout = 0;
            while (sd_sec_read !== 1'b1) begin
                @(negedge clk);
                timeout = timeout + 1;
                if (timeout > 40)
                    $fatal(1, "[FAIL] sector %0d was never requested", expected_address);
            end
            if (sd_sec_read_addr !== expected_address)
                $fatal(1, "[FAIL] requested sector %0d, expected %0d",
                       sd_sec_read_addr, expected_address);
            for (i = 0; i < 512; i = i + 1) begin
                @(negedge clk);
                sd_sec_read_data_valid = 1'b1;
                sd_sec_read_data = file_byte(file_byte_base + i, profile, length);
                if (insert_gaps && ((i % 97) == 20)) begin
                    @(negedge clk);
                    sd_sec_read_data_valid = 1'b0;
                end
            end
            @(negedge clk);
            sd_sec_read_data_valid = 1'b0;
            repeat (end_gap) @(negedge clk);
            sd_sec_read_end = 1'b1;
            @(negedge clk);
            sd_sec_read_end = 1'b0;
        end
    endtask

    task begin_scan;
        input [31:0] first_sector;
        input [31:0] last_sector;
        input [2:0] target;
        begin
            observed_found_count = 0;
            catalog_check = 1'b1;
            if (!ready) $fatal(1, "[FAIL] scan started while busy");
            @(negedge clk);
            scan_start_sector = first_sector;
            scan_max_sector = last_sector;
            scan_target_count = target;
            scan_start = 1'b1;
            @(negedge clk);
            scan_start = 1'b0;
            if (scan_done) $fatal(1, "[FAIL] stale scan_done after new request");
        end
    endtask

    task finish_scan;
        integer timeout;
        begin
            timeout = 0;
            while (scan_done !== 1'b1) begin
                @(negedge clk);
                timeout = timeout + 1;
                if (timeout > 40) $fatal(1, "[FAIL] scan never completed");
            end
            if (!ready || observed_found_count != expected_found_count ||
                scan_found_total !== expected_found_count)
                $fatal(1, "[FAIL] final scan status/count mismatch");
            repeat (6) begin
                @(negedge clk);
                if (sd_sec_read) $fatal(1, "[FAIL] extra read after scan completion");
            end
            catalog_check = 1'b0;
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst = 1'b0;
        sd_init_done = 1'b1;
        @(negedge clk);

        expected_found_count = 4;
        expected_found_sector[0] = 11;
        expected_found_sector[1] = 14;
        expected_found_sector[2] = 17;
        expected_found_sector[3] = 18;
        begin_scan(10, 30, 4);
        serve_sector(10, 0, 0, 0, 0, 1);
        serve_sector(11, 1, 513, 0, 3, 0);
        serve_sector(13, 2, 32'h100000, 0, 1, 1);
        serve_sector(14, 1, 512, 0, 0, 0);
        serve_sector(15, 3, 1024, 0, 2, 0);
        serve_sector(16, 4, 1024, 0, 0, 0);
        serve_sector(17, 1, 0, 0, 1, 0);
        serve_sector(18, 1, 1024, 0, 0, 0);
        finish_scan;
        $display("[PASS] scan rejects malformed formats, rounds file sizes, stops at target");

        expected_found_count = 1;
        expected_found_sector[0] = 30;
        begin_scan(30, 31, 4);
        serve_sector(30, 1, 1024, 0, 0, 0);
        finish_scan;
        $display("[PASS] matched-file jump beyond scan limit terminates");

        expected_found_count = 2;
        expected_found_sector[0] = 40;
        expected_found_sector[1] = 42;
        begin_scan(40, 42, 4);
        serve_sector(40, 1, 512, 0, 0, 0);
        serve_sector(41, 0, 0, 0, 2, 1);
        serve_sector(42, 1, 512, 0, 1, 0);
        finish_scan;
        $display("[PASS] inclusive scan limit and partial catalog");

        expected_found_count = 0;
        begin_scan(50, 52, 4);
        serve_sector(50, 0, 0, 0, 3, 0);
        serve_sector(51, 2, 512, 0, 0, 0);
        serve_sector(52, 4, 512, 0, 1, 1);
        finish_scan;
        $display("[PASS] no-image scan completes without extra reads");

        // Load after scans: delayed SDRAM acknowledgement and three sectors
        // exercise BGR triplets spanning sector boundaries and byte stalls.
        @(negedge clk);
        load_sector = 80;
        load_start = 1'b1;
        @(negedge clk);
        load_start = 1'b0;
        serve_sector(80, 1, 1080, 0, 2, 1);
        if (!write_req) $fatal(1, "[FAIL] valid load did not request SDRAM write");
        repeat (6) begin
            @(negedge clk);
            if (sd_sec_read) $fatal(1, "[FAIL] payload read before write acknowledgement");
            if (!write_req) $fatal(1, "[FAIL] write request did not persist until acknowledgement");
        end
        pixel_count = 0;
        pixel_check = 1'b1;
        write_req_ack = 1'b1;
        @(negedge clk);
        write_req_ack = 1'b0;
        serve_sector(80, 1, 1080, 0, 0, 1);
        serve_sector(81, 1, 1080, 512, 3, 1);
        serve_sector(82, 1, 1080, 1024, 1, 1);
        repeat (3) @(negedge clk);
        if (!ready || write_req || sd_sec_read || pixel_count != 342)
            $fatal(1, "[FAIL] load completion or pixel count mismatch (%0d)", pixel_count);
        pixel_check = 1'b0;
        $display("[PASS] load after scan preserves byte/pixel order across sectors and stalls");

        @(negedge clk);
        load_sector = 90;
        load_start = 1'b1;
        @(negedge clk);
        load_start = 1'b0;
        serve_sector(90, 2, 1080, 0, 1, 0);
        repeat (3) @(negedge clk);
        if (!ready || write_req || sd_sec_read)
            $fatal(1, "[FAIL] malformed load did not return to idle");
        $display("[PASS] malformed load header returns to idle");
        $display("[PASS] BMP scanner/load regression complete");
        $finish;
    end

    initial begin
        #500000;
        $fatal(1, "[FAIL] watchdog timeout");
    end
endmodule
