`timescale 1ns/1ps
// Load-side cover-crop, area-average thumbnail, box blur and bilinear sampler.
// Coordinates on both interfaces are BMP bottom-up coordinates. Source pixels
// arrive in increasing x, then increasing y order, and obey valid/ready.
// Only the thumbnail is retained; all expensive arithmetic runs during image
// loading. RAM reads are synchronous and RAM contents are never reset.
`ifndef BMP_BLUR_BACKGROUND_V
`define BMP_BLUR_BACKGROUND_V
module bmp_blur_background #(
    parameter integer DST_WIDTH=640,
    parameter integer DST_HEIGHT=480,
    parameter integer THUMB_WIDTH=32,
    parameter integer THUMB_HEIGHT=24,
    parameter integer BLUR_PASSES=3,
    parameter integer BRIGHTNESS_NUM=3,
    parameter integer BRIGHTNESS_SHIFT=2
)(
    input clk, rst, cancel, start,
    input [11:0] width,
    input [10:0] height,
    output ingest_ready,
    input pixel_valid,
    input [23:0] pixel_rgb,
    input [11:0] pixel_x,
    input [10:0] pixel_y,
    input finish,
    output reg done,
    input sample_req,
    input [15:0] sample_x, sample_y,
    output reg sample_valid,
    output reg [23:0] sample_rgb
);
    localparam IDLE=0, INIT_MUL=1, INIT_COMPARE=2, INIT_FINISH=3,
        CLEAR=4, INGEST=5, PIXEL_CHECK=6, ACC_FETCH=7, ACC_STORE=8,
        AVG_FETCH=9, AVG_RED=10, AVG_GREEN=11, AVG_BLUE=12, AVG_WRITE=13,
        BLUR_BEGIN=14, BLUR_FETCH=15, BLUR_USE=16, BLUR_DIV_R=17,
        BLUR_DIV_G=18, BLUR_DIV_B=19, BLUR_WRITE=20,
        WAIT_SAMPLE=21, SAMPLE_MUL_X=22, SAMPLE_DIV_X=23, SAMPLE_X=24,
        SAMPLE_MUL_Y=25, SAMPLE_DIV_Y=26, SAMPLE_Y=27,
        SAMPLE_FETCH=28, SAMPLE_SAVE=29, H0_PREP=30, H0_SAVE=31,
        H1_PREP=32, H1_SAVE=33, V_PREP=34, V_SAVE=35,
        MULTIPLY=36, DIVIDE=37, BLUR_FETCH2=38, SAMPLE_FETCH2=39, V_ADD=40;
    reg [5:0] state, div_return, mul_return;
    reg [11:0] src_w;
    reg [10:0] src_h;
    reg [31:0] aspect_w, aspect_h;
    reg wide_crop;
    reg [15:0] crop_w, crop_h, crop_left, crop_bottom;
    reg [5:0] bw, bh, clear_x, bx, by, held_bucket;
    reg [16:0] x_rem, y_rem;
    reg [23:0] held_rgb;
    reg [11:0] held_x;
    reg [10:0] held_y;
    reg finish_seen, avg_resume;
    reg [5:0] avg_x, avg_y;
    reg [7:0] avg_r, avg_g, avg_b;
    // One thumbnail row of wide sums, not a full frame of accumulators.
    localparam integer ACC_AW=$clog2(THUMB_WIDTH)>0?$clog2(THUMB_WIDTH):1;
    localparam integer THUMB_AW=$clog2(THUMB_WIDTH*THUMB_HEIGHT)>0?$clog2(THUMB_WIDTH*THUMB_HEIGHT):1;
    reg [119:0] accum [0:THUMB_WIDTH-1]; /* fehdl force_ram=1, ram_style="bram" */
    reg [119:0] accum_q;
    localparam integer THUMB_PIXELS=THUMB_WIDTH*THUMB_HEIGHT;
    reg [23:0] thumb_a [0:THUMB_PIXELS-1]; /* fehdl force_ram=1, ram_style="bram" */
    reg [23:0] thumb_b [0:THUMB_PIXELS-1]; /* fehdl force_ram=1, ram_style="bram" */
    reg [23:0] thumb_a_q, thumb_b_q;
    reg blur_source, final_source;
    wire [23:0] thumb_q=(state==BLUR_USE?blur_source:final_source)?thumb_b_q:thumb_a_q;
    reg [5:0] blur_x, blur_y;
    reg [3:0] blur_tap;
    reg [7:0] blur_pass;
    reg [11:0] blur_r, blur_g, blur_b;
    reg [7:0] blur_avg_r, blur_avg_g, blur_avg_b;
    reg [THUMB_AW-1:0] read_addr;
    // The tap address cone (clamp + shift + add over 6 adders, 12 levels) used to
    // feed the inferred RAM address port directly and missed 10 ns on
    // sd_card_clk.  Registering it turns that into a register-to-register path
    // and costs one extra wait cycle in each fetch state.
    reg [THUMB_AW-1:0] read_addr_q;
    reg [15:0] sx, sy;
    reg [31:0] coord_product;
    reg [15:0] x_fp;
    reg [5:0] x0, x1, y0, y1;
    reg [7:0] fx, fy;
    reg [1:0] sample_tap, color;
    reg [23:0] p00, p01, p10, p11;
    reg signed [17:0] mul_a;
    reg signed [8:0] mul_b;
    reg signed [26:0] mul_result, mul_base;
    reg signed [17:0] h0, h1;
    // One restoring divider is shared by crop setup, thumbnail averages and
    // sampling coordinates. No variable combinational divide is inferred.
    reg [31:0] div_bits, div_rem, div_den;
    reg [5:0] div_count;
    wire [32:0] div_trial={div_rem,div_bits[31]};
    wire div_ge=div_trial>={1'b0,div_den};
    wire [32:0] div_sub=div_trial-{1'b0,div_den};
    wire [31:0] div_next={div_bits[30:0],div_ge};
    wire held_inside=held_x>=crop_left && held_x<crop_left+crop_w &&
        held_y>=crop_bottom && held_y<crop_bottom+crop_h;
    wire [31:0] sum_r=accum_q[119:88]+held_rgb[23:16];
    wire [31:0] sum_g=accum_q[87:56]+held_rgb[15:8];
    wire [31:0] sum_b=accum_q[55:24]+held_rgb[7:0];
    wire [23:0] sum_n=accum_q[23:0]+1'b1;
    wire [THUMB_AW-1:0] avg_addr=avg_y*THUMB_WIDTH+avg_x;
    wire [THUMB_AW-1:0] blur_addr=blur_y*THUMB_WIDTH+blur_x;
    // The interpolation sum feeds a scale, a compare and the output mux, which
    // put ~6 levels between the multiplier register and sample_rgb and showed up
    // as both a setup miss and a hold violation on sd_card_clk.  Keep the sum in
    // its own register and let V_SAVE do only the byte scale.
    reg signed [26:0] interpolation_r;
    wire [7:0] normalized=interpolation_r[23:16];
    wire [31:0] brightness=(normalized*BRIGHTNESS_NUM)>>BRIGHTNESS_SHIFT;
    assign ingest_ready=state==INGEST && !finish_seen && !cancel && !start;

    function [7:0] channel;
        input [23:0] rgb;
        input [1:0] c;
        begin
            case(c)
                0:channel=rgb[23:16];
                1:channel=rgb[15:8];
                default:channel=rgb[7:0];
            endcase
        end
    endfunction
    wire [7:0] c00=channel(p00,color);
    wire [7:0] c01=channel(p01,color);
    wire [7:0] c10=channel(p10,color);
    wire [7:0] c11=channel(p11,color);
    // Thumbnail coordinates are 0..31, so 7 signed bits are enough. Keeping
    // them as `integer` made the tap-delta adders, the >=bw/bh clamps and the
    // ny*THUMB_WIDTH multiply 32-bit wide, which put this cone on the 10 ns
    // sd_card_clk critical path once the frame FIFOs grew.
    reg signed [6:0] nx,ny;
    reg [6:0] nxu,nyu;
    always @* begin
        nx={1'b0,blur_x}; ny={1'b0,blur_y};
        case(blur_tap)
            0:begin nx=nx-1;ny=ny-1;end
            1:ny=ny-1;
            2:begin nx=nx+1;ny=ny-1;end
            3:nx=nx-1;
            5:nx=nx+1;
            6:begin nx=nx-1;ny=ny+1;end
            7:ny=ny+1;
            8:begin nx=nx+1;ny=ny+1;end
            default:begin end
        endcase
        if(nx<0)nx=0;
        if(ny<0)ny=0;
        if(nx>=bw)nx=bw-1;
        if(ny>=bh)ny=bh-1;
        // After clamping both are non-negative, so index with unsigned values:
        // ny*THUMB_WIDTH then reduces to a shift instead of a signed multiply.
        nxu=nx; nyu=ny;
        read_addr=0;
        if(state==BLUR_FETCH||state==BLUR_FETCH2)read_addr=nyu*THUMB_WIDTH+nxu;
        else case(sample_tap)
            0:read_addr=y0*THUMB_WIDTH+x0;
            1:read_addr=y0*THUMB_WIDTH+x1;
            2:read_addr=y1*THUMB_WIDTH+x0;
            default:read_addr=y1*THUMB_WIDTH+x1;
        endcase
    end
    // One physical write port and one synchronous read port per RAM.
    // Explicit address muxing is required by TD's RAM inference template.
    wire ram_write_allowed=!cancel && !start;
    wire accum_we=ram_write_allowed && (state==CLEAR || state==ACC_STORE || state==AVG_WRITE);
    wire [ACC_AW-1:0] accum_ra=state==AVG_FETCH?avg_x[ACC_AW-1:0]:held_bucket[ACC_AW-1:0];
    wire [ACC_AW-1:0] accum_wa=state==CLEAR?clear_x[ACC_AW-1:0]:
        state==AVG_WRITE?avg_x[ACC_AW-1:0]:held_bucket[ACC_AW-1:0];
    wire [119:0] accum_wd=state==ACC_STORE?{sum_r,sum_g,sum_b,sum_n}:120'd0;
    wire thumb_a_we=ram_write_allowed && (state==AVG_WRITE || (state==BLUR_WRITE && blur_source));
    wire thumb_b_we=ram_write_allowed && state==BLUR_WRITE && !blur_source;
    wire [THUMB_AW-1:0] thumb_a_wa=state==AVG_WRITE?avg_addr:blur_addr;
    wire [23:0] thumb_a_wd=state==AVG_WRITE?{avg_r,avg_g,avg_b}:{blur_avg_r,blur_avg_g,blur_avg_b};
    always @(posedge clk) begin
        if(accum_we)accum[accum_wa]<=accum_wd;
        if(state==AVG_FETCH || state==ACC_FETCH)accum_q<=accum[accum_ra];
    end
    always @(posedge clk) begin
        if(thumb_a_we)thumb_a[thumb_a_wa]<=thumb_a_wd;
        read_addr_q<=read_addr;
        thumb_a_q<=thumb_a[read_addr_q];
    end
    always @(posedge clk) begin
        if(thumb_b_we)thumb_b[blur_addr]<={blur_avg_r,blur_avg_g,blur_avg_b};
        thumb_b_q<=thumb_b[read_addr_q];
    end

    always @(posedge clk or posedge rst)begin
        if(rst)begin
            state<=IDLE;div_return<=IDLE;mul_return<=IDLE;
            src_w<=1;src_h<=1;aspect_w<=0;aspect_h<=0;wide_crop<=0;
            crop_w<=1;crop_h<=1;crop_left<=0;crop_bottom<=0;
            bw<=1;bh<=1;clear_x<=0;bx<=0;by<=0;held_bucket<=0;
            x_rem<=0;y_rem<=0;held_rgb<=0;held_x<=0;held_y<=0;
            finish_seen<=0;avg_resume<=0;avg_x<=0;avg_y<=0;
            avg_r<=0;avg_g<=0;avg_b<=0;blur_source<=0;final_source<=0;
            blur_x<=0;blur_y<=0;blur_tap<=0;blur_pass<=0;
            blur_r<=0;blur_g<=0;blur_b<=0;
            blur_avg_r<=0;blur_avg_g<=0;blur_avg_b<=0;
            sx<=0;sy<=0;coord_product<=0;x_fp<=0;
            x0<=0;x1<=0;y0<=0;y1<=0;fx<=0;fy<=0;sample_tap<=0;color<=0;
            p00<=0;p01<=0;p10<=0;p11<=0;mul_a<=0;mul_b<=0;
            mul_result<=0;mul_base<=0;h0<=0;h1<=0;interpolation_r<=0;
            div_bits<=0;div_rem<=0;div_den<=1;div_count<=0;
            done<=0;sample_valid<=0;sample_rgb<=0;
        end else begin
            sample_valid<=0;
            if(cancel)begin
                state<=IDLE;done<=0;finish_seen<=0;
            end else if(start)begin
                src_w<=width==0?12'd1:width;
                src_h<=height==0?11'd1:height;
                state<=INIT_MUL;done<=0;finish_seen<=0;
            end else begin
                if(finish)finish_seen<=1;
                case(state)
                    IDLE:begin end
                    INIT_MUL:begin
                        aspect_w<=src_w*DST_HEIGHT;
                        aspect_h<=src_h*DST_WIDTH;
                        state<=INIT_COMPARE;
                    end
                    INIT_COMPARE:begin
                        wide_crop<=aspect_w>=aspect_h;
                        div_bits<=aspect_w>=aspect_h?aspect_h:aspect_w;
                        div_den<=aspect_w>=aspect_h?DST_HEIGHT:DST_WIDTH;
                        div_rem<=0;div_count<=32;div_return<=INIT_FINISH;state<=DIVIDE;
                    end
                    INIT_FINISH:begin
                        if(wide_crop)begin
                            crop_w<=div_bits==0?16'd1:div_bits[15:0];crop_h<=src_h;
                            crop_left<=(src_w-(div_bits==0?16'd1:div_bits[15:0]))>>1;crop_bottom<=0;
                            bw<=div_bits==0?6'd1:(div_bits<THUMB_WIDTH?div_bits[5:0]:THUMB_WIDTH);
                            bh<=src_h<THUMB_HEIGHT?src_h:THUMB_HEIGHT;
                        end else begin
                            crop_w<=src_w;crop_h<=div_bits==0?16'd1:div_bits[15:0];crop_left<=0;
                            crop_bottom<=(src_h-(div_bits==0?16'd1:div_bits[15:0])+1'b1)>>1;
                            bw<=src_w<THUMB_WIDTH?src_w:THUMB_WIDTH;
                            bh<=div_bits==0?6'd1:(div_bits<THUMB_HEIGHT?div_bits[5:0]:THUMB_HEIGHT);
                        end
                        clear_x<=0;state<=CLEAR;
                    end
                    CLEAR:begin
                        if(clear_x==THUMB_WIDTH-1)begin
                            bx<=0;by<=0;x_rem<=0;y_rem<=0;state<=INGEST;
                        end else clear_x<=clear_x+1'b1;
                    end
                    INGEST:begin
                        if(finish_seen || (finish && !pixel_valid))begin
                            avg_x<=0;avg_y<=by;avg_resume<=0;state<=AVG_FETCH;
                        end else if(pixel_valid)begin
                            held_rgb<=pixel_rgb;held_x<=pixel_x;held_y<=pixel_y;state<=PIXEL_CHECK;
                        end
                    end
                    PIXEL_CHECK:begin
                        if(!held_inside)state<=INGEST;
                        else begin
                            held_bucket<=held_x==crop_left?6'd0:bx;
                            if(held_x==crop_left)begin
                                bx<=bw>=crop_w?6'd1:6'd0;
                                x_rem<=bw>=crop_w?bw-crop_w:bw;
                                if(held_y!=crop_bottom)begin
                                    if(y_rem+bh>=crop_h)begin
                                        y_rem<=y_rem+bh-crop_h;by<=by+1'b1;
                                        avg_x<=0;avg_y<=by;avg_resume<=1;state<=AVG_FETCH;
                                    end else begin y_rem<=y_rem+bh;state<=ACC_FETCH;end
                                end else state<=ACC_FETCH;
                            end else begin
                                if(x_rem+bw>=crop_w)begin x_rem<=x_rem+bw-crop_w;bx<=bx+1'b1;end
                                else x_rem<=x_rem+bw;
                                state<=ACC_FETCH;
                            end
                        end
                    end
                    ACC_FETCH:state<=ACC_STORE;
                    ACC_STORE:state<=INGEST;
                    AVG_FETCH:state<=AVG_RED;
                    AVG_RED:begin
                        div_bits<=accum_q[119:88];
                        div_den<=accum_q[23:0]==0?32'd1:{8'd0,accum_q[23:0]};
                        div_rem<=0;div_count<=32;div_return<=AVG_GREEN;state<=DIVIDE;
                    end
                    AVG_GREEN:begin
                        avg_r<=div_bits[7:0];div_bits<=accum_q[87:56];
                        div_rem<=0;div_count<=32;div_return<=AVG_BLUE;state<=DIVIDE;
                    end
                    AVG_BLUE:begin
                        avg_g<=div_bits[7:0];div_bits<=accum_q[55:24];
                        div_rem<=0;div_count<=32;div_return<=AVG_WRITE;state<=DIVIDE;
                    end
                    AVG_WRITE:begin
                        // This state's RAM write uses avg_b from the prior
                        // divider cycle, assigned by DIVIDE below.
                        if(avg_x==bw-1)begin
                            if(avg_resume)state<=ACC_FETCH;else state<=BLUR_BEGIN;
                        end else begin avg_x<=avg_x+1'b1;state<=AVG_FETCH;end
                    end
                    BLUR_BEGIN:begin
                        blur_source<=0;blur_x<=0;blur_y<=0;blur_tap<=0;blur_pass<=0;
                        blur_r<=0;blur_g<=0;blur_b<=0;
                        if(BLUR_PASSES==0)begin final_source<=0;done<=1;state<=WAIT_SAMPLE;end
                        else state<=BLUR_FETCH;
                    end
                    BLUR_FETCH:state<=BLUR_FETCH2;
                    BLUR_FETCH2:state<=BLUR_USE;
                    BLUR_USE:begin
                        blur_r<=blur_r+thumb_q[23:16];blur_g<=blur_g+thumb_q[15:8];blur_b<=blur_b+thumb_q[7:0];
                        if(blur_tap==8)begin
                            div_bits<={20'd0,blur_r+thumb_q[23:16]};
                            div_den<=9;div_rem<=0;div_count<=32;
                            div_return<=BLUR_DIV_R;state<=DIVIDE;
                        end
                        else begin blur_tap<=blur_tap+1'b1;state<=BLUR_FETCH;end
                    end
                    BLUR_DIV_R:begin
                        blur_avg_r<=div_bits[7:0];
                        div_bits<={20'd0,blur_g};div_den<=9;div_rem<=0;div_count<=32;
                        div_return<=BLUR_DIV_G;state<=DIVIDE;
                    end
                    BLUR_DIV_G:begin
                        blur_avg_g<=div_bits[7:0];
                        div_bits<={20'd0,blur_b};div_den<=9;div_rem<=0;div_count<=32;
                        div_return<=BLUR_DIV_B;state<=DIVIDE;
                    end
                    BLUR_DIV_B:begin
                        blur_avg_b<=div_bits[7:0];state<=BLUR_WRITE;
                    end
                    BLUR_WRITE:begin
                        blur_r<=0;blur_g<=0;blur_b<=0;blur_tap<=0;
                        if(blur_x==bw-1)begin
                            blur_x<=0;
                            if(blur_y==bh-1)begin
                                blur_y<=0;
                                if(blur_pass==BLUR_PASSES-1)begin
                                    final_source<=~blur_source;done<=1;state<=WAIT_SAMPLE;
                                end else begin
                                    blur_pass<=blur_pass+1'b1;blur_source<=~blur_source;state<=BLUR_FETCH;
                                end
                            end else begin blur_y<=blur_y+1'b1;state<=BLUR_FETCH;end
                        end else begin blur_x<=blur_x+1'b1;state<=BLUR_FETCH;end
                    end
                    WAIT_SAMPLE:if(sample_req)begin
                        sx<=sample_x>=DST_WIDTH?DST_WIDTH-1:sample_x;
                        sy<=sample_y>=DST_HEIGHT?DST_HEIGHT-1:sample_y;
                        state<=SAMPLE_MUL_X;
                    end
                    SAMPLE_MUL_X:begin coord_product<=(sx*2+1)*bw;state<=SAMPLE_DIV_X;end
                    SAMPLE_DIV_X:begin
                        div_bits<=coord_product<<7;div_den<=DST_WIDTH;
                        div_rem<=0;div_count<=32;div_return<=SAMPLE_X;state<=DIVIDE;
                    end
                    SAMPLE_X:begin
                        if(div_bits<128)x_fp<=0;
                        else if(div_bits>((bw-1)*256+128))x_fp<=(bw-1)*256;
                        else x_fp<=div_bits-128;
                        state<=SAMPLE_MUL_Y;
                    end
                    SAMPLE_MUL_Y:begin coord_product<=(sy*2+1)*bh;state<=SAMPLE_DIV_Y;end
                    SAMPLE_DIV_Y:begin
                        div_bits<=coord_product<<7;div_den<=DST_HEIGHT;
                        div_rem<=0;div_count<=32;div_return<=SAMPLE_Y;state<=DIVIDE;
                    end
                    SAMPLE_Y:begin
                        x0<=x_fp[15:8];x1<=x_fp[15:8]>=bw-1?bw-1:x_fp[15:8]+1'b1;fx<=x_fp[7:0];
                        if(div_bits<128)begin y0<=0;y1<=bh>1?6'd1:6'd0;fy<=0;end
                        else if(div_bits>((bh-1)*256+128))begin y0<=bh-1;y1<=bh-1;fy<=0;end
                        else begin
                            y0<=(div_bits-128)>>8;
                            y1<=((div_bits-128)>>8)>=bh-1?bh-1:((div_bits-128)>>8)+1'b1;
                            fy<=div_bits[7:0]-8'd128;
                        end
                        sample_tap<=0;state<=SAMPLE_FETCH;
                    end
                    SAMPLE_FETCH:state<=SAMPLE_FETCH2;
                    SAMPLE_FETCH2:state<=SAMPLE_SAVE;
                    SAMPLE_SAVE:begin
                        case(sample_tap)
                            0:p00<=thumb_q;1:p01<=thumb_q;2:p10<=thumb_q;default:p11<=thumb_q;
                        endcase
                        if(sample_tap==3)begin color<=0;state<=H0_PREP;end
                        else begin sample_tap<=sample_tap+1'b1;state<=SAMPLE_FETCH;end
                    end
                    H0_PREP:begin
                        mul_a<=$signed({1'b0,c01})-$signed({1'b0,c00});mul_b<=$signed({1'b0,fx});
                        mul_base<=$signed({1'b0,c00,8'd0});mul_return<=H0_SAVE;state<=MULTIPLY;
                    end
                    H0_SAVE:begin h0<=mul_base+mul_result;state<=H1_PREP;end
                    H1_PREP:begin
                        mul_a<=$signed({1'b0,c11})-$signed({1'b0,c10});mul_b<=$signed({1'b0,fx});
                        mul_base<=$signed({1'b0,c10,8'd0});mul_return<=H1_SAVE;state<=MULTIPLY;
                    end
                    H1_SAVE:begin h1<=mul_base+mul_result;state<=V_PREP;end
                    V_PREP:begin
                        mul_a<=h1-h0;mul_b<=$signed({1'b0,fy});
                        mul_base<=$signed(h0)<<<8;mul_return<=V_ADD;state<=MULTIPLY;
                    end
                    V_ADD:begin
                        interpolation_r<=mul_base+mul_result+27'sd32768;state<=V_SAVE;
                    end
                    V_SAVE:begin
                        case(color)
                            0:sample_rgb[23:16]<=brightness>255?8'd255:brightness[7:0];
                            1:sample_rgb[15:8]<=brightness>255?8'd255:brightness[7:0];
                            default:sample_rgb[7:0]<=brightness>255?8'd255:brightness[7:0];
                        endcase
                        if(color==2)begin sample_valid<=1;state<=WAIT_SAMPLE;end
                        else begin color<=color+1'b1;state<=H0_PREP;end
                    end
                    MULTIPLY:begin mul_result<=mul_a*mul_b;state<=mul_return;end
                    DIVIDE:begin
                        div_bits<=div_next;div_rem<=div_ge?div_sub[31:0]:div_trial[31:0];
                        if(div_count==1)begin
                            if(div_return==AVG_WRITE)avg_b<=div_next[7:0];
                            state<=div_return;
                        end else div_count<=div_count-1'b1;
                    end
                    default:state<=IDLE;
                endcase
            end
        end
    end
endmodule
`endif
