// Self-check for contrast_rgb against fixtures/contrast_golden.mem.
// 8 levels x 256 inputs, three channels with distinct values (x, 255-x,
// x ^ 0x5A) => 2048 RGB combinations / 6144 channel checks, plus explicit
// black / white / 128-midpoint / low / high saturation cases.
//
// The expected table is the independent Codex-generated fixture; it is never
// modified or recomputed from the RTL.
`timescale 1ns/1ps

module tb_contrast_rgb;

    reg  [23:0] rgb;
    reg  [2:0]  level;
    wire [23:0] out_rgb;

    reg  [7:0]   golden [0:2047];
    reg  [1023:0] path;
    integer      level_i, x_i;
    integer      errors;
    reg  [7:0]   ch_r, ch_g, ch_b;

    contrast_rgb dut(.rgb(rgb), .level(level), .out_rgb(out_rgb));

    initial begin
        errors = 0;
        if (!$value$plusargs("golden=%s", path))
            path = "fixtures/contrast_golden.mem";
        $readmemh(path, golden);

        // 6144 channel checks.
        for (level_i = 0; level_i < 8; level_i = level_i + 1) begin
            for (x_i = 0; x_i < 256; x_i = x_i + 1) begin
                ch_r  = x_i[7:0];        // R input = x_i
                ch_g  = 255 - x_i;       // G input = 255 - x_i (low byte is value)
                ch_b  = x_i ^ 8'h5A;     // B input = x_i ^ 0x5A (low byte is value)
                rgb   = {ch_r, ch_g, ch_b};
                level = level_i[2:0];
                #1;
                if (out_rgb[23:16] !== golden[level_i*256 + x_i]) begin
                    $display("FAIL L=%0d x=%0d R got %02h exp %02h",
                             level_i, x_i, out_rgb[23:16], golden[level_i*256+x_i]);
                    errors = errors + 1;
                end
                if (out_rgb[15:8] !== golden[level_i*256 + (255 - x_i)]) begin
                    $display("FAIL L=%0d x=%0d G got %02h exp %02h",
                             level_i, x_i, out_rgb[15:8], golden[level_i*256+(255-x_i)]);
                    errors = errors + 1;
                end
                if (out_rgb[7:0] !== golden[level_i*256 + (x_i ^ 8'h5A)]) begin
                    $display("FAIL L=%0d x=%0d B got %02h exp %02h",
                             level_i, x_i, out_rgb[7:0], golden[level_i*256+(x_i^8'h5A)]);
                    errors = errors + 1;
                end
            end
        end

        // Special cases.
        rgb = 24'h000000; level = 3'd2; #1;   // black, identity
        if (out_rgb !== 24'h000000) begin $display("FAIL black"); errors = errors + 1; end
        rgb = 24'hFFFFFF; level = 3'd2; #1;   // white, identity
        if (out_rgb !== 24'hFFFFFF) begin $display("FAIL white"); errors = errors + 1; end
        rgb = 24'h808080; level = 3'd2; #1;   // 128 midpoint, identity
        if (out_rgb !== 24'h808080) begin $display("FAIL mid-128"); errors = errors + 1; end
        rgb = 24'h000000; level = 3'd4; #1;   // low saturation (gain 6 clamps to 0)
        if (out_rgb !== 24'h000000) begin $display("FAIL low sat"); errors = errors + 1; end
        rgb = 24'hFFFFFF; level = 3'd4; #1;   // high saturation (gain 6 clamps to 255)
        if (out_rgb !== 24'hFFFFFF) begin $display("FAIL high sat"); errors = errors + 1; end

        if (errors == 0) begin
            $display("PASS: contrast_rgb 6144 channel checks + special cases");
            $finish;
        end else begin
            $fatal(1, "contrast_rgb self-check FAILED with %0d errors", errors);
        end
    end

endmodule
