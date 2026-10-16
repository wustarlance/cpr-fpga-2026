// Chinese mask for the existing 640x480 layout. All inputs are already
// frame snapshots in the 25 MHz video domain. RGB/sync latency is zero.
// Pixel decisions are combinational; only subtitle offset is sequential.
module cpr_text_zh #(parameter UNCALIBRATED_PRESSURE=0, PAGE_STATUS_ENABLE=0)(
    input wire clk, rst, frame_start, de,
    input wire [9:0] x, y,
    input wire [1:0] mode, rate, depth, brightness,
    input wire [2:0] contrast,
    input wire auto_running, pause_warning, rotate_due, fault, beat, bpm_valid,
    input wire [11:0] page_status,
    input wire [15:0] count_bcd, interval_bcd, pause_bcd,
    input wire [23:0] rotate_bcd,
    input wire [11:0] bpm_bcd,
    output wire text_pixel,
    output reg [23:0] text_color
);
    reg [9:0] offset;
    reg [1:0] frames;
    always @(posedge clk or posedge rst) begin
        if (rst) begin offset<=0; frames<=0; end
        else if (frame_start && (mode!=1 || auto_running)) begin
            if (frames==2) begin
                frames<=0;
                offset<=offset==575 ? 10'd0 : offset+1'b1;
            end else frames<=frames+1'b1;
        end
    end

    // The whole character decode below is registered instead of combinational.
    // Every input it consumes except the pixel coordinate is a frame snapshot,
    // and the coordinate is advanced by one pixel before decoding, so the
    // registered value is exactly the decode of the pixel that is present when
    // it is used -- the mask stays pixel aligned. The enable is gated by de so
    // the x=639 -> x=0 line rollover lands on the next line's first pixel.
    // This removes the x -> cell_x -> range compare -> message mux chain from
    // the 40 ns video path.
    wire [9:0] x_next = x + 10'd1;
    reg [5:0] message_id, index;
    reg [7:0] override_code;
    reg use_override, enabled;
    reg [3:0] glyph_column, glyph_row;
    reg [10:0] scroll_position;
    reg [5:0] cell_x;
    reg [5:0] d_message_id, d_index;
    reg [7:0] d_override_code;
    reg d_use_override, d_enabled;
    reg [3:0] d_glyph_column, d_glyph_row;
    reg [23:0] d_text_color;
    wire [7:0] string_code;
    wire [15:0] row_bits;
    wire [7:0] glyph_code=use_override ? override_code : string_code;
    wire [1:0] header_page=(page_status[3]||page_status[2]) ? page_status[5:4] : page_status[10:9];
    wire [23:0] rate_color=rate==2 ? 24'h20d060 : rate==0 ? 24'h607080 : 24'hffb020;
    wire [23:0] depth_color=depth==2 ? 24'h20d060 : depth==0 ? 24'h607080 : depth==3 ? 24'hff4040 : 24'hffb020;
    cpr_zh_strings u_strings(.message_id(message_id),.index(index),.code(string_code));
    cpr_font16_rom u_font(.code(glyph_code),.row(glyph_row),.row_bits(row_bits));
    assign text_pixel=!rst && de && enabled && row_bits[15-glyph_column];

    // IDs 1..10 are decimal digits in the generated font. All other IDs
    // come exclusively from cpr_zh_strings; never send raw UTF-8 bytes here.
    function [7:0] digit_id;
        input [3:0] digit;
        begin digit_id=digit<10 ? {4'd0,digit}+8'd1 : 8'd13; end
    endfunction

    always @(*) begin
        d_message_id=63; d_index=0; d_override_code=0; d_use_override=0;
        d_enabled=0; d_glyph_column=x_next[3:0]; d_glyph_row=y[3:0];
        d_text_color=24'hffffff; scroll_position=0; cell_x=0;
        if (x_next>=16 && x_next<624 && y<16) begin
            d_enabled=1; cell_x=x_next[9:4]-6'd1;
            if (cell_x<4) begin d_message_id=0; d_index=cell_x; end
            else if(cell_x>=5 && cell_x<9) begin d_message_id=mode==0 ? 1 : mode==1 ? 2 : 3; d_index=cell_x-6'd5; end
            else if(PAGE_STATUS_ENABLE && cell_x==10) d_message_id=page_status[0] ? 42 : 6;
            else if(PAGE_STATUS_ENABLE && cell_x==11) begin
                d_use_override=1; d_override_code=(page_status[11]||page_status[3]||page_status[2]) ? digit_id({2'd0,header_page}+4'd1) : 8'd13;
            end else if(PAGE_STATUS_ENABLE && cell_x==12) begin d_use_override=1; d_override_code=12; end
            else if(PAGE_STATUS_ENABLE && cell_x==13) begin d_use_override=1; d_override_code=digit_id({1'b0,page_status[8:6]}); end
            else if(PAGE_STATUS_ENABLE && cell_x>=15 && cell_x<18) begin
                d_message_id=page_status[1] ? 9 : page_status[2] ? 8 : page_status[3] ? 7 : page_status[11] ? 10 : 11;
                d_index=cell_x-6'd15;
                if(page_status[1]||page_status[2])d_text_color=24'hffd080;
            end else if(cell_x>=20 && cell_x<22) begin d_message_id=4; d_index=cell_x-6'd20; end
            else if(cell_x==22)begin d_use_override=1;d_override_code=digit_id({2'd0,brightness});end
            else if(cell_x>=25 && cell_x<27)begin d_message_id=5;d_index=cell_x-6'd25;end
            else if(cell_x==27)begin d_use_override=1;d_override_code=digit_id({1'b0,contrast});end
            else if(mode==1 && cell_x>=31 && cell_x<34)begin d_message_id=auto_running ? 12 : 13;d_index=cell_x-6'd31;end
        end else if(mode==2 && x_next>=400 && x_next<624 && y>=16 && !y[4]) begin
            d_enabled=1; cell_x=x_next[9:4]-6'd25; d_index=cell_x;
            case(y[8:5])
                2: begin
                    d_message_id=14;
                    if(cell_x>=8 && cell_x<12)begin d_use_override=1;d_override_code=digit_id(count_bcd[15-(cell_x-6'd8)*4 -:4]);end
                end
                3: begin
                    d_text_color=rate_color;
                    if(cell_x<2)d_message_id=15;
                    else if(cell_x>=4 && cell_x<7)begin
                        d_use_override=1; d_override_code=bpm_valid ? digit_id(bpm_bcd[11-(cell_x-6'd4)*4 -:4]) : 8'd13;
                    end else if(cell_x>=7 && cell_x<10)begin d_message_id=41;d_index=cell_x-6'd7;end
                    else if(cell_x>=11 && cell_x<13)begin d_message_id=!bpm_valid || rate==0 ? 19 : rate==1 ? 16 : rate==2 ? 17 : 18;d_index=cell_x-6'd11;end
                end
                4: begin
                    d_text_color=depth_color;
                    if(cell_x<4)d_message_id=UNCALIBRATED_PRESSURE ? 20 : 22;
                    else if(cell_x==6)begin d_use_override=1;d_override_code=digit_id({2'd0,depth});end
                    else if(cell_x>=8 && cell_x<12)begin d_message_id=UNCALIBRATED_PRESSURE ? 21 : 23;d_index=cell_x-6'd8;end
                end
                5,6: begin
                    d_message_id=y[8:5]==5 ? 24 : 25;
                    if(y[8:5]==6 && pause_warning)d_text_color=24'hff4040;
                    if(cell_x>=5 && cell_x<9)begin
                        d_use_override=1;
                        d_override_code=digit_id(y[8:5]==5 ? interval_bcd[15-(cell_x-6'd5)*4 -:4] : pause_bcd[15-(cell_x-6'd5)*4 -:4]);
                    end else if(cell_x>=10 && cell_x<12)begin d_message_id=27;d_index=cell_x-6'd10;end
                end
                7: begin
                    d_message_id=26;
                    if(rotate_due)d_text_color=24'hffb020;
                    if(cell_x>=4 && cell_x<10)begin d_use_override=1;d_override_code=digit_id(rotate_bcd[23-(cell_x-6'd4)*4 -:4]);end
                    else if(cell_x>=11 && cell_x<13)begin d_message_id=27;d_index=cell_x-6'd11;end
                end
                9: begin d_message_id=pause_warning ? 28 : 29;if(pause_warning)d_text_color=24'hff4040;end
                10:begin d_message_id=rotate_due ? 30 : 31;if(rotate_due)d_text_color=24'hffb020;end
                11:begin d_message_id=fault ? 32 : UNCALIBRATED_PRESSURE ? 33 : 36;d_text_color=fault ? 24'hff4040 : 24'h70c090;end
                12:begin d_message_id=beat ? 34 : 35;d_text_color=beat ? 24'hffffff : 24'h91a4b0;end
                default:d_message_id=63;
            endcase
        end else if(x_next>=16 && x_next<(mode==2 ? 368 : 624) && y>=448 && y<464) begin
            scroll_position={1'b0,x_next}-11'd16+{1'b0,offset};
            if(scroll_position>=576)scroll_position=scroll_position-11'd576;
            if(scroll_position>=576)scroll_position=scroll_position-11'd576;
            d_enabled=scroll_position<512;
            d_glyph_column=scroll_position[3:0];
            d_index=scroll_position[9:4];
            d_message_id=mode==0 ? 37 : mode==1 ? 38 : UNCALIBRATED_PRESSURE ? 39 : 40;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            message_id<=63; index<=0; override_code<=0; use_override<=0;
            enabled<=0; glyph_column<=0; glyph_row<=0; text_color<=24'hffffff;
        end else if (de) begin
            message_id<=d_message_id; index<=d_index;
            override_code<=d_override_code; use_override<=d_use_override;
            enabled<=d_enabled; glyph_column<=d_glyph_column;
            glyph_row<=d_glyph_row; text_color<=d_text_color;
        end
    end
endmodule
