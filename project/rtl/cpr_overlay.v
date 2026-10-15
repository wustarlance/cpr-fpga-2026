// Fixed 640x480 OSD, 25 MHz pixel clock, asynchronous active-high reset.
// All status inputs must use this clock. No RGB pixel register is added.
// Official 640x480 VS is negative: capture status on its falling edge.
// Display saturation never changes the underlying training counters.
module cpr_overlay #(parameter UNCALIBRATED_PRESSURE = 0,
                     parameter PAGE_STATUS_ENABLE = 0)(
    input wire clk, rst, vs, de,
    input wire [23:0] rgb,
    input wire [1:0] mode,
    input wire [31:0] count,
    input wire [1:0] rate,
    input wire pause_warning, rotate_due, beat,
    input wire [1:0] depth_grade,
    input wire [15:0] interval_ms, pause_ms,
    input wire [31:0] rotate_remaining_ms,
    input wire [7:0] bpm,
    input wire bpm_valid, sensor_fault,
    input wire [1:0] brightness_level,
    input wire [2:0] contrast_level,
    input wire auto_running,
    input wire [11:0] page_status,
    output reg [23:0] out_rgb
);
reg [9:0] x, y;
reg last_de, last_vs;
reg [1:0] frame_mode, frame_rate, frame_depth, frame_brightness;
reg frame_pause, frame_rotate, frame_beat, frame_fault, frame_bpm_valid;
reg beat_seen;
reg [2:0] frame_contrast;
reg frame_auto_running;
reg [11:0] frame_page;
wire [1:0] header_page = frame_page[3] || frame_page[2] ? frame_page[5:4] : frame_page[10:9];
wire [5:0] subtitle_addr;
wire [7:0] subtitle_code;
wire [34:0] subtitle_glyph;
wire subtitle_pixel;
cpr_subtitle_rom #(.UNCALIBRATED_PRESSURE(UNCALIBRATED_PRESSURE)) u_subtitle_message(
    .mode(frame_mode), .addr(subtitle_addr), .code(subtitle_code));
font5x7_rom u_subtitle_font(.code(subtitle_code), .pixels(subtitle_glyph));
scroll_text u_subtitles(
    .clk(clk), .rst_n(!rst), .frame_start(last_vs && !vs), .de(de),
    .x(x), .y(y), .enable(1'b1),
    .scroll_enable((frame_mode != 2'd1) || frame_auto_running),
    .text_addr(subtitle_addr), .glyph_pixels(subtitle_glyph), .text_pixel(subtitle_pixel));
reg [15:0] count_bcd, interval_bcd, pause_bcd;
reg [23:0] rotate_bcd;
reg [11:0] bpm_bcd;

// Constant-bound shift/add-3 conversion; no runtime divider is inferred.
function [15:0] to_bcd4;
    input [13:0] binary;
    integer i, j;
    reg [15:0] bcd;
    begin
        bcd = 0;
        for (i = 13; i >= 0; i = i - 1) begin
            for (j = 0; j < 4; j = j + 1)
                if (bcd[j*4 +: 4] >= 5)
                    bcd[j*4 +: 4] = bcd[j*4 +: 4] + 4'd3;
            bcd = {bcd[14:0],binary[i]};
        end
        to_bcd4 = bcd;
    end
endfunction
function [23:0] to_bcd6;
    input [19:0] binary;
    integer i, j;
    reg [23:0] bcd;
    begin
        bcd = 0;
        for (i = 19; i >= 0; i = i - 1) begin
            for (j = 0; j < 6; j = j + 1)
                if (bcd[j*4 +: 4] >= 5)
                    bcd[j*4 +: 4] = bcd[j*4 +: 4] + 4'd3;
            bcd = {bcd[22:0],binary[i]};
        end
        to_bcd6 = bcd;
    end
endfunction
function [11:0] to_bcd3;
    input [7:0] binary;
    integer i, j;
    reg [11:0] bcd;
    begin
        bcd = 0;
        for (i = 7; i >= 0; i = i - 1) begin
            for (j = 0; j < 3; j = j + 1)
                if (bcd[j*4 +: 4] >= 5)
                    bcd[j*4 +: 4] = bcd[j*4 +: 4] + 4'd3;
            bcd = {bcd[10:0],binary[i]};
        end
        to_bcd3 = bcd;
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        x <= 0; y <= 0; last_de <= 0; last_vs <= 1;
        frame_page <= 0;
        frame_mode <= 0; frame_rate <= 0; frame_depth <= 0;
        frame_brightness <= 3; frame_contrast <= 2; frame_auto_running <= 0;
        frame_pause <= 0; frame_rotate <= 0;
        frame_beat <= 0; frame_fault <= 0; frame_bpm_valid <= 0;
        beat_seen <= 0; count_bcd <= 0; interval_bcd <= 0;
        pause_bcd <= 0; rotate_bcd <= 0; bpm_bcd <= 0;
    end
    else begin
        last_de <= de; last_vs <= vs;
        if (beat) beat_seen <= 1;       // ← 帧内"见过节拍"标记
        if (last_vs && !vs) begin       // VS 下降沿 = 新帧开始
            x <= 0; y <= 0;
            frame_page <= PAGE_STATUS_ENABLE ? page_status : 12'd0;
            frame_mode <= mode; frame_rate <= rate; frame_depth <= depth_grade;
            frame_brightness <= brightness_level;
            frame_contrast <= contrast_level;
            frame_auto_running <= auto_running;
            frame_pause <= pause_warning; frame_rotate <= rotate_due;
            frame_beat <= beat || beat_seen; frame_fault <= sensor_fault;
            frame_bpm_valid <= bpm_valid; beat_seen <= 0;
            count_bcd <= to_bcd4(count > 32'd9999 ? 14'd9999 : count[13:0]);
            interval_bcd <= to_bcd4(interval_ms > 16'd9999 ? 14'd9999 : interval_ms[13:0]);
            pause_bcd <= to_bcd4(pause_ms > 16'd9999 ? 14'd9999 : pause_ms[13:0]);
            rotate_bcd <= to_bcd6(rotate_remaining_ms > 32'd999999 ? 20'd999999 : rotate_remaining_ms[19:0]);
            bpm_bcd <= to_bcd3(bpm);
        end
        else begin                      // 帧内：只推进扫描坐标
            if (de) begin if (x < 10'd639) x <= x + 1'b1; end
            else x <= 0;
            if (last_de && !de && y < 10'd479) y <= y + 1'b1;
        end
    end
end

// Five columns by seven rows, displayed at 2x scale.
function [34:0] glyph;
    input [7:0] code;
    begin
        case (code)
            "0": glyph = {5'b01110,5'b10001,5'b10011,5'b10101,5'b11001,5'b10001,5'b01110};
            "1": glyph = {5'b00100,5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
            "2": glyph = {5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b01000,5'b11111};
            "3": glyph = {5'b11110,5'b00001,5'b00001,5'b01110,5'b00001,5'b00001,5'b11110};
            "4": glyph = {5'b00010,5'b00110,5'b01010,5'b10010,5'b11111,5'b00010,5'b00010};
            "5": glyph = {5'b11111,5'b10000,5'b10000,5'b11110,5'b00001,5'b00001,5'b11110};
            "6": glyph = {5'b01110,5'b10000,5'b10000,5'b11110,5'b10001,5'b10001,5'b01110};
            "7": glyph = {5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b01000,5'b01000};
            "8": glyph = {5'b01110,5'b10001,5'b10001,5'b01110,5'b10001,5'b10001,5'b01110};
            "9": glyph = {5'b01110,5'b10001,5'b10001,5'b01111,5'b00001,5'b00001,5'b01110};
            "A": glyph = {5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
            "B": glyph = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10001,5'b10001,5'b11110};
            "C": glyph = {5'b01111,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b01111};
            "D": glyph = {5'b11110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b11110};
            "E": glyph = {5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b11111};
            "F": glyph = {5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b10000};
            "G": glyph = {5'b01111,5'b10000,5'b10000,5'b10111,5'b10001,5'b10001,5'b01111};
            "H": glyph = {5'b10001,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
            "I": glyph = {5'b01110,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
            "L": glyph = {5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111};
            "M": glyph = {5'b10001,5'b11011,5'b10101,5'b10101,5'b10001,5'b10001,5'b10001};
            "N": glyph = {5'b10001,5'b11001,5'b10101,5'b10011,5'b10001,5'b10001,5'b10001};
            "O": glyph = {5'b01110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
            "P": glyph = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10000,5'b10000,5'b10000};
            "R": glyph = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10100,5'b10010,5'b10001};
            "S": glyph = {5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110};
            "T": glyph = {5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100};
            "U": glyph = {5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
            "W": glyph = {5'b10001,5'b10001,5'b10001,5'b10101,5'b10101,5'b10101,5'b01010};
            "V": glyph = {5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01010,5'b00100};
            ":": glyph = {5'b00000,5'b00100,5'b00100,5'b00000,5'b00100,5'b00100,5'b00000};
            "-": glyph = {5'b00000,5'b00000,5'b00000,5'b11111,5'b00000,5'b00000,5'b00000};
            default: glyph = 35'b0;
        endcase
    end
endfunction
function [7:0] digit;
    input [3:0] bcd;
    begin digit = {4'b0011,bcd}; end
endfunction

reg [7:0] character;
reg [34:0] pixels;
reg [23:0] text_color, rate_color, depth_color;
// Training reserves x0..383 for the tutorial; feedback fits x384..639.
// BMP pixels keep their original coordinates (no scaling or added latency).
localparam [9:0] TRAIN_PANEL_LEFT = 10'd384;
localparam [9:0] TRAIN_TEXT_LEFT = 10'd400;
localparam [9:0] TRAIN_TEXT_RIGHT = 10'd624;
localparam [9:0] TRAIN_SUBTITLE_RIGHT = 10'd368;
wire [5:0] cell_x = (frame_mode == 2 && y >= 16) ?
    x[9:4] - 6'd25 : x[9:4] - 6'd1;
wire [3:0] line_y = y[8:5];
wire [2:0] glyph_x = x[3:1];
wire [2:0] glyph_y = y[3:1];
reg text_pixel;
integer glyph_index;
always @(*) begin
    character = " ";
    case (frame_rate)
        1: rate_color = 24'hffb020;
        2: rate_color = 24'h20d060;
        3: rate_color = 24'hffb020;
        default: rate_color = 24'h607080;
    endcase
    case (frame_depth)
        1: depth_color = 24'hffb020;
        2: depth_color = 24'h20d060;
        3: depth_color = 24'hff4040;
        default: depth_color = 24'h607080;
    endcase
    text_color = 24'hffffff;
    if (y < 16) begin
        case (cell_x)
            0: character = "C"; 1: character = "P"; 2: character = "R";
            4: character = frame_mode == 0 ? "T" : frame_mode == 1 ? "A" : "T";
            5: character = frame_mode == 0 ? "E" : frame_mode == 1 ? "U" : "R";
            6: character = frame_mode == 0 ? "A" : frame_mode == 1 ? "T" : "A";
            7: character = frame_mode == 0 ? "C" : frame_mode == 1 ? "O" : "I";
            8: character = frame_mode == 0 ? "H" : frame_mode == 1 ? " " : "N";
            10: character = PAGE_STATUS_ENABLE ? (frame_page[0] ? "T" : "P") : " ";
            11: character = !PAGE_STATUS_ENABLE ? " " :
                (frame_page[11] || frame_page[3] || frame_page[2]) ?
                digit({2'b0,header_page}+4'd1) : "-";
            12: character = PAGE_STATUS_ENABLE ? "-" : " ";
            13: character = PAGE_STATUS_ENABLE ? digit({1'b0,frame_page[8:6]}) : " ";
            14: character = !PAGE_STATUS_ENABLE ? " " : frame_page[1] ? "E" :
                frame_page[2] ? "M" : frame_page[3] ? "L" : " ";
            16: character = "B"; 17: character = "R"; 18: character = "I";
            19: character = "G"; 20: character = "H"; 21: character = "T";
            22: character = ":"; 23: character = digit({2'b0,frame_brightness});
            26: character = "C"; 27: character = "O"; 28: character = "N";
            29: character = "T"; 30: character = ":";
            31: character = digit({1'b0,frame_contrast});
            default: character = " ";
        endcase
    end else if (frame_mode == 2 && x >= TRAIN_TEXT_LEFT && x < TRAIN_TEXT_RIGHT) begin
        case (line_y)
            2: case (cell_x)
                0: character = "C"; 1: character = "O"; 2: character = "U";
                3: character = "N"; 4: character = "T";
                8: character = digit(count_bcd[15:12]); 9: character = digit(count_bcd[11:8]);
                10: character = digit(count_bcd[7:4]); 11: character = digit(count_bcd[3:0]);
                default: character = " ";
            endcase
            3: begin
                text_color = rate_color;
                case (cell_x)
                    0: character = "B"; 1: character = "P"; 2: character = "M";
                    4: character = frame_bpm_valid ? digit(bpm_bcd[11:8]) : "-";
                    5: character = frame_bpm_valid ? digit(bpm_bcd[7:4]) : "-";
                    6: character = frame_bpm_valid ? digit(bpm_bcd[3:0]) : "-";
                    9: character = frame_rate == 1 ? "S" : frame_rate == 2 ? "G" : frame_rate == 3 ? "F" : "-";
                    10: character = frame_rate == 1 ? "L" : frame_rate == 2 ? "O" : frame_rate == 3 ? "A" : "-";
                    11: character = frame_rate == 1 ? "O" : frame_rate == 2 ? "O" : frame_rate == 3 ? "S" : "-";
                    12: character = frame_rate == 1 ? "W" : frame_rate == 2 ? "D" : frame_rate == 3 ? "T" : "-";
                    default: character = " ";
                endcase
            end
            4: begin
                text_color = depth_color;
                case (cell_x)
                    0: character = UNCALIBRATED_PRESSURE ? "P" : "D";
                    1: character = UNCALIBRATED_PRESSURE ? "R" : "E";
                    2: character = UNCALIBRATED_PRESSURE ? "E" : "P";
                    3: character = UNCALIBRATED_PRESSURE ? "S" : "T";
                    4: character = UNCALIBRATED_PRESSURE ? "S" : "H";
                    6: character = digit({2'b0,frame_depth});
                    8: character = UNCALIBRATED_PRESSURE ? "U" : " ";
                    9: character = UNCALIBRATED_PRESSURE ? "N" : " ";
                    10: character = UNCALIBRATED_PRESSURE ? "C" : " ";
                    11: character = UNCALIBRATED_PRESSURE ? "A" : " ";
                    12: character = UNCALIBRATED_PRESSURE ? "L" : " ";
                    default: character = " ";
                endcase
            end
            5: case (cell_x)
                0: character = "I"; 1: character = "N"; 2: character = "T";
                5: character = digit(interval_bcd[15:12]); 6: character = digit(interval_bcd[11:8]);
                7: character = digit(interval_bcd[7:4]); 8: character = digit(interval_bcd[3:0]);
                10: character = "M"; 11: character = "S";
                default: character = " ";
            endcase
            6: begin
                if (frame_pause) text_color = 24'hff4040;
                case (cell_x)
                    0: character = "P"; 1: character = "A"; 2: character = "U";
                    3: character = "S"; 4: character = "E";
                    6: character = digit(pause_bcd[15:12]); 7: character = digit(pause_bcd[11:8]);
                    8: character = digit(pause_bcd[7:4]); 9: character = digit(pause_bcd[3:0]);
                    11: character = "M"; 12: character = "S";
                    default: character = " ";
                endcase
            end
            7: begin
                if (frame_rotate) text_color = 24'hffb020;
                case (cell_x)
                    0: character = "R"; 1: character = "O"; 2: character = "T";
                    4: character = digit(rotate_bcd[23:20]); 5: character = digit(rotate_bcd[19:16]);
                    6: character = digit(rotate_bcd[15:12]); 7: character = digit(rotate_bcd[11:8]);
                    8: character = digit(rotate_bcd[7:4]); 9: character = digit(rotate_bcd[3:0]);
                    11: character = "M"; 12: character = "S";
                    default: character = " ";
                endcase
            end
            9: begin
                if (frame_pause) text_color = 24'hff4040;
                case (cell_x)
                    0: character = "P"; 1: character = "A"; 2: character = "U";
                    3: character = "S"; 4: character = "E"; 5: character = ":";
                    7: character = digit({3'b0,frame_pause});
                    default: character = " ";
                endcase
            end
            10: begin
                if (frame_rotate) text_color = 24'hffb020;
                case (cell_x)
                    0: character = "R"; 1: character = "O"; 2: character = "T";
                    3: character = "A"; 4: character = "T"; 5: character = "E";
                    6: character = ":"; 8: character = digit({3'b0,frame_rotate});
                    default: character = " ";
                endcase
            end
            11: begin
                text_color = frame_fault ? 24'hff4040 : 24'h206040;
                case (cell_x)
                    0: character = "F"; 1: character = "A"; 2: character = "U";
                    3: character = "L"; 4: character = "T"; 5: character = ":";
                    7: character = digit({3'b0,frame_fault});
                    default: character = " ";
                endcase
            end
            12: case (cell_x)
                0: character = "B"; 1: character = "E"; 2: character = "A";
                3: character = "T"; 4: character = ":";
                7: character = digit({3'b0,frame_beat});
                default: character = " ";
            endcase
            default: character = " ";
        endcase
    end
    pixels = glyph(character);
    glyph_index = 34 - glyph_y * 5 - glyph_x;
    text_pixel = 0;
    if (x >= 16 && x < 624 && !y[4] && glyph_y < 7 && glyph_x < 5 &&
        (y < 16 || (frame_mode == 2 && x >= TRAIN_TEXT_LEFT && x < TRAIN_TEXT_RIGHT)))
        text_pixel = pixels[glyph_index];

    out_rgb = rgb;
    if (de) begin
        if (frame_mode == 2 && x >= TRAIN_PANEL_LEFT && y >= 16) begin
            out_rgb = 24'h101820;
            if (x < TRAIN_PANEL_LEFT + 10'd4) out_rgb = 24'h405060;
        end
        if (y < 16) begin
            case (frame_mode)
                0: out_rgb = 24'h204080;
                1: out_rgb = 24'h206040;
                default: out_rgb = 24'h805020;
            endcase
        end
        if (frame_mode == 2 && x >= 624 && x < 632) begin
            if (y >= 96 && y < 112) out_rgb = rate_color;
            if (y >= 128 && y < 144) out_rgb = depth_color;
            if (y >= 352 && y < 368) out_rgb = frame_fault ? 24'hff4040 : 24'h206040;
            if (y >= 384 && y < 400) out_rgb = frame_beat ? 24'hffffff : 24'h304050;
        end
        if (y >= 448 && y < 464 && x >= 16 && x < 624 &&
            (frame_mode != 2 || x < TRAIN_SUBTITLE_RIGHT)) begin
            out_rgb = 24'h182430;
            if (subtitle_pixel) out_rgb = 24'hffffff;
        end
        if (text_pixel) out_rgb = text_color;
    end
end
endmodule
