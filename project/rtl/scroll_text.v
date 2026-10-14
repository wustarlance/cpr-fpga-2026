// scroll_text: per-frame scrolling text mask over a fixed 640x480 window.
// No RGB or pixel register is added; text_addr / text_pixel are combinational
// and driven by x, y and the internal pixel offset. The caller latches
// frame_start as a one-clock-wide per-frame event in this clock domain.
//
//   Each character cell is 16x16 px; the glyph is 5x7 at 2x scale, drawn in
//   the top-left 10x14 (right 6 px and bottom 2 px blank).
//   Window: x in [X_LEFT, X_LEFT+WINDOW_WIDTH), y in [Y_TOP, Y_TOP+16).
//   SPAN  = (TEXT_LENGTH + GAP_CELLS) * 16  (total scroll cycle in pixels).
//
// offset starts at 0; every FRAMES_PER_PIXEL accepted frame events
// (enable && scroll_enable) advance offset by 1, wrapping at SPAN-1 -> 0.
// enable=0 or scroll_enable=0 freezes offset and the frame-event count.
// enable=0 blanks the mask; scroll_enable=0 (with enable=1) keeps a static
// subtitle. Reset clears offset/count and immediately blanks the mask.
//
// p = ((x - X_LEFT) + offset) mod SPAN ; char_idx = p >> 4.
// char_idx >= TEXT_LENGTH is the wrap gap -> blank. Otherwise text_addr =
// char_idx, glyph_x = (p[3:0])>>1, glyph_y = (y-Y_TOP)>>1, and the pixel is
// glyph_pixels[34 - glyph_y*5 - glyph_x] when glyph_x<5, glyph_y<7 and
// de & enable & rst_n are all active. text_addr never depends on glyph_pixels.

module scroll_text #(
    parameter integer TEXT_LENGTH      = 32,
    parameter integer GAP_CELLS        = 4,
    parameter integer X_LEFT           = 16,
    parameter integer Y_TOP            = 448,
    parameter integer WINDOW_WIDTH     = 608,
    parameter integer FRAMES_PER_PIXEL = 3
)(
    input  wire        clk,
    input  wire        rst_n,          // async, active low
    input  wire        frame_start,    // 1 clk-wide per-frame event
    input  wire        de,
    input  wire [9:0]  x,
    input  wire [9:0]  y,
    input  wire        enable,
    input  wire        scroll_enable,
    output reg  [5:0]  text_addr,      // 0 .. TEXT_LENGTH-1
    input  wire [34:0] glyph_pixels,
    output reg         text_pixel
);

    // ---- compile-time constants ----
    function integer clog2;
        input integer v;
        integer i;
        begin
            i = 0;
            while ((1 << i) < v) i = i + 1;
            clog2 = i;
        end
    endfunction

    localparam integer SPAN      = (TEXT_LENGTH + GAP_CELLS) * 16;
    localparam integer OFFSET_W  = clog2(SPAN);                 // fits max SPAN
    localparam integer FCNT_W    = (FRAMES_PER_PIXEL > 1) ? clog2(FRAMES_PER_PIXEL) : 1;
    localparam integer SUB_LOOPS = (WINDOW_WIDTH + SPAN - 1) / SPAN + 1;

    // ---- scroll offset + frame-event counter ----
    reg [OFFSET_W-1:0] offset;
    reg [FCNT_W-1:0]   frame_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            offset    <= {OFFSET_W{1'b0}};
            frame_cnt <= {FCNT_W{1'b0}};
        end else if (enable && scroll_enable && frame_start) begin
            if (frame_cnt == FRAMES_PER_PIXEL - 1) begin
                frame_cnt <= {FCNT_W{1'b0}};
                offset    <= (offset == SPAN - 1) ? {OFFSET_W{1'b0}} : offset + 1'b1;
            end else begin
                frame_cnt <= frame_cnt + 1'b1;
            end
        end
    end

    // ---- combinational address / mask ----
    reg [9:0]        x_rel;
    reg [3:0]        y_rel;
    reg [12:0]       accum;      // x_rel + offset, no overflow at 13 bits
    reg [OFFSET_W-1:0] p;
    reg [6:0]        char_idx;
    reg [2:0]        glyph_x, glyph_y;
    integer          i;

    always @(*) begin
        text_addr  = 6'd0;
        x_rel = 0; y_rel = 0; accum = 0; p = 0;
        char_idx = 0; glyph_x = 0; glyph_y = 0; i = 0;
        if (rst_n &&
            (x >= X_LEFT) && (x < X_LEFT + WINDOW_WIDTH) &&
            (y >= Y_TOP)   && (y < Y_TOP + 16)) begin
            x_rel = x - X_LEFT[9:0];
            y_rel = y - Y_TOP[9:0];
            accum = 13'b0 + x_rel;           // 13-bit context, zero-extended
            accum = accum + offset;
            // mod SPAN by bounded constant subtraction (no runtime divider).
            for (i = 0; i < SUB_LOOPS; i = i + 1) begin
                if (accum >= SPAN) accum = accum - SPAN;
            end
            p = accum[OFFSET_W-1:0];
            char_idx = p >> 4;
            if (char_idx < TEXT_LENGTH) begin
                text_addr = char_idx[5:0];
                glyph_x   = p[3:0] >> 1;
                glyph_y   = y_rel >> 1;

            end
        end
    end

    // Keep the address path independent of glyph data. Defaults also cover
    // off-window and inter-character blank space; no helper latch is needed.
    always @(*) begin
        text_pixel = 1'b0;
        if (rst_n && de && enable &&
            (x >= X_LEFT) && (x < X_LEFT + WINDOW_WIDTH) &&
            (y >= Y_TOP) && (y < Y_TOP + 16) &&
            (char_idx < TEXT_LENGTH) && (glyph_x < 5) && (glyph_y < 7))
            text_pixel = glyph_pixels[34 - glyph_y*5 - glyph_x];
    end
endmodule
