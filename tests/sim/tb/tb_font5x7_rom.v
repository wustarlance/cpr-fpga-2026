// Self-check for font5x7_rom against fixtures/glyph5x7_golden.mem.
// Compares all 256 character codes bit-for-bit. The 9-hex-digit fixture
// values have their top (36th) bit always 0; we read them into 36-bit words
// and compare the low 35 bits against the ROM output.
`timescale 1ns/1ps

module tb_font5x7_rom;

    reg  [7:0]  code;
    wire [34:0] pixels;

    reg  [35:0]  golden [0:255];
    reg  [1023:0] path;
    integer      c, errors;

    font5x7_rom dut(.code(code), .pixels(pixels));

    initial begin
        errors = 0;
        if (!$value$plusargs("glyph=%s", path))
            path = "fixtures/glyph5x7_golden.mem";
        $readmemh(path, golden);

        for (c = 0; c < 256; c = c + 1) begin
            code = c[7:0];
            #1;
            if (pixels !== golden[c][34:0]) begin
                $display("FAIL code=%0d (0x%02h) got %09h exp %09h",
                         c, c[7:0], pixels, golden[c][34:0]);
                errors = errors + 1;
            end
        end

        if (errors == 0) begin
            $display("PASS: font5x7_rom matched glyph5x7_golden.mem for all 256 codes");
            $finish;
        end else begin
            $fatal(1, "font5x7_rom self-check FAILED with %0d errors", errors);
        end
    end

endmodule
