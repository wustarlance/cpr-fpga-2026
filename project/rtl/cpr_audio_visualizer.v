// 640x480 audio footer, all ports synchronous to the 25 MHz video clock.
// Consume the SAME gated 24-bit signed PCM words supplied to HDMI.
// Two registered pixel stages: RAM read, then RGB/VS/DE composition.
// No SDRAM access, new clock, multiplier, or audio backpressure.
module cpr_audio_visualizer #(parameter integer DECIMATION = 4)(
    input wire clk, rst, enable,
    input wire vs, de,
    input wire [23:0] rgb,
    input wire sample_valid,
    input wire [23:0] sample_left, sample_right,
    output reg out_vs, out_de,
    output reg [23:0] out_rgb,
    output reg [5:0] level,
    output reg waveform_valid
);
localparam integer DIV_BITS = DECIMATION > 1 ? $clog2(DECIMATION) : 1;
reg [9:0] x, y;
reg last_vs, last_de;
wire frame_start = last_vs && !vs;
always @(posedge clk or posedge rst) begin
    if (rst) begin x<=0; y<=0; last_vs<=1; last_de<=0; end
    else begin
        last_vs<=vs; last_de<=de;
        if (frame_start) begin x<=0; y<=0; end
        else begin
            if (de) begin if (x<639) x<=x+1'b1; end
            else x<=0;
            if (last_de && !de && y<479) y<=y+1'b1;
        end
    end
end

// The waveform has a fixed display gain: one vertical pixel per 2^19 PCM
// units, clamped to +/-5 pixels. VU remains linear full scale, max(L,R).
function [3:0] wave_height;
    input [23:0] value;
    reg signed [4:0] q;
    begin
        q=$signed(value[23:19]);
        if (q>5) wave_height=0;
        else if (q< -5) wave_height=10;
        else wave_height=5-q;
    end
endfunction
reg valid_q;
reg [23:0] magnitude_left, magnitude_right;
reg [3:0] height_q;
always @(posedge clk or posedge rst) begin
    if (rst) begin valid_q<=0; magnitude_left<=0; magnitude_right<=0; height_q<=5; end
    else begin
        valid_q<=sample_valid && enable;
        if (sample_valid && enable) begin
            // 24'h800000 is representable as an UNSIGNED magnitude.
            magnitude_left<=sample_left[23] ? (~sample_left+24'd1) : sample_left;
            magnitude_right<=sample_right[23] ? (~sample_right+24'd1) : sample_right;
            height_q<=wave_height(sample_left);
        end
    end
end
wire [5:0] left_level = magnitude_left[23] ? 6'd63 : magnitude_left[22:17];
wire [5:0] right_level = magnitude_right[23] ? 6'd63 : magnitude_right[22:17];
wire [5:0] sample_level = left_level>right_level ? left_level : right_level;
reg [5:0] peak;
wire [5:0] released_level = level>4 ? level-6'd4 : 6'd0;
reg frame_had_audio;
reg write_bank, display_bank, capture_ready;
reg [7:0] write_index;
reg [DIV_BITS-1:0] sample_div;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        level<=0; peak<=0; frame_had_audio<=0;
        write_bank<=0; display_bank<=1; capture_ready<=0;
        write_index<=0; sample_div<=0; waveform_valid<=0;
    end else if (!enable) begin
        level<=0; peak<=0; frame_had_audio<=0;
        write_bank<=0; display_bank<=1; capture_ready<=0;
        write_index<=0; sample_div<=0; waveform_valid<=0;
    end else begin
        if (valid_q) begin
            frame_had_audio<=1;
            if (sample_level>peak) peak<=sample_level;
        end
        if (frame_start) begin
            level<=peak>released_level ? peak : released_level;
            // A sample on the publication edge belongs to the new VU window.
            peak<=valid_q ? sample_level : 6'd0;
            frame_had_audio<=valid_q;
            if (!frame_had_audio) begin
                waveform_valid<=0; capture_ready<=0;
                write_index<=0; sample_div<=0;
            end else if (capture_ready) begin
                // Publish only a fully written bank, in vertical blanking.
                display_bank<=write_bank; write_bank<=~write_bank;
                waveform_valid<=1; capture_ready<=0;
                write_index<=0; sample_div<=0;
            end
        end else if (valid_q && !capture_ready) begin
            if (sample_div==DECIMATION-1) begin
                sample_div<=0;
                if (write_index==255) capture_ready<=1;
                else write_index<=write_index+1'b1;
            end else sample_div<=sample_div+1'b1;
        end
    end
end

// Two 256-sample banks. A completed bank waits for VS; further scope samples
// are intentionally skipped until publication. HDMI audio is never stalled.
// No RAM reset loop: validity prevents display of uninitialized memory.
reg [3:0] samples [0:511];
wire capture_write = enable && valid_q && !capture_ready &&
                     sample_div==DECIMATION-1 && !frame_start;
wire [9:0] wave_x = x-10'd16;
wire [7:0] read_index = x>=16 && x<528 ? wave_x[8:1] : 8'd0;
reg [3:0] read_height;
always @(posedge clk) begin
    if (capture_write) samples[{write_bank,write_index}]<=height_q;
    if (waveform_valid) read_height<=samples[{display_bank,read_index}];
    else read_height<=4'd5;
end

reg vs_q, de_q, enable_q, wave_valid_q;
reg [9:0] x_q, y_q;
reg [23:0] rgb_q;
reg [5:0] level_q;
reg [23:0] composed;
reg [34:0] letter;
reg [5:0] glyph_index;
wire [9:0] bar_x=x_q-10'd552;
wire [9:0] trace_y=10'd467+(wave_valid_q ? {6'd0,read_height} : 10'd5);
always @* begin
    composed=rgb_q; letter=0; glyph_index=0;
    if (enable_q && de_q && y_q>=464 && y_q<480) begin
        composed=24'h081420;
        if (y_q==464 || y_q==479) composed=24'h405060;
        if (x_q>=16 && x_q<528 && y_q==472) composed=24'h203848;
        if (x_q>=16 && x_q<528 && y_q==trace_y) composed=24'h50e0d0;
        if (x_q>=552 && x_q<616 && y_q>=467 && y_q<478) begin
            composed=24'h203040;
            if (level_q!=0 && (bar_x<{4'd0,level_q} || level_q==63) && bar_x[2:0]!=7) begin
                if (bar_x<40) composed=24'h20d060;
                else if (bar_x<56) composed=24'hffb020;
                else composed=24'hff4040;
            end
        end
        if (y_q>=469 && y_q<476) begin
            if (x_q>=536 && x_q<541) begin
                letter={5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01010,5'b00100};
                glyph_index=34-(y_q-469)*5-(x_q-536);
                if (letter[glyph_index]) composed=24'hb6c9d5;
            end
            if (x_q>=542 && x_q<547) begin
                letter={5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                glyph_index=34-(y_q-469)*5-(x_q-542);
                if (letter[glyph_index]) composed=24'hb6c9d5;
            end
        end
    end
end
always @(posedge clk or posedge rst) begin
    if (rst) begin
        vs_q<=1; de_q<=0; rgb_q<=0; x_q<=0; y_q<=0;
        enable_q<=0; wave_valid_q<=0; level_q<=0;
        out_vs<=1; out_de<=0; out_rgb<=0;
    end else begin
        vs_q<=vs; de_q<=de; rgb_q<=rgb; x_q<=x; y_q<=y;
        enable_q<=enable; wave_valid_q<=waveform_valid; level_q<=level;
        out_vs<=vs_q; out_de<=de_q; out_rgb<=composed;
    end
end
endmodule
