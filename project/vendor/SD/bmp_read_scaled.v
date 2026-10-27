`timescale 1ns/1ps
// Load-side nearest-neighbour contain scaler. SDRAM always receives a complete
// bottom-up DST_WIDTH x DST_HEIGHT frame; the existing write-side vertical flip
// converts it to HDMI order. Positive-height, uncompressed 24-bit BMP only.
// One sector and one source row are buffered. No SD transaction is started
// until its predecessor has been consumed, so arbitrary enlargement and output
// backpressure cannot lose SD bytes. Pixel coordinates use exact integer
// remainders (floor(x*src_w/fit_w)), with no accumulated fixed-point drift.
module bmp_read_scaled #(
    parameter integer MAX_WIDTH = 2048,
    parameter integer MAX_HEIGHT = 1536,
    parameter integer DST_WIDTH = 640,
    parameter integer DST_HEIGHT = 480,
    parameter integer BLUR_BACKGROUND = 0,
    parameter integer BG_BRIGHTNESS_NUM = 3,
    parameter integer BG_BRIGHTNESS_SHIFT = 2,
    parameter integer WAIT_TIMEOUT_CYCLES = 100_000_000
)(
    input clk, rst,
    input cancel,
    input sd_sec_ready,
    input sd_sec_read_error,
    output reg abort_sd,
    output reg operation_error,
    output reg [2:0] error_code,
    output ready,
    input scan_start,
    input [31:0] scan_start_sector, scan_max_sector,
    input [2:0] scan_target_count,
    output reg scan_done, scan_found_valid,
    output reg [31:0] scan_found_sector,
    output reg [2:0] scan_found_total,
    input load_start,
    input [31:0] load_sector,
    input sd_init_done,
    output reg [3:0] state_code,
    input [15:0] bmp_width, bmp_height, // legacy interface; destination is parameterized
    output reg write_req,
    input write_req_ack,
    output reg sd_sec_read,
    output reg [31:0] sd_sec_read_addr,
    input [7:0] sd_sec_read_data,
    input sd_sec_read_data_valid, sd_sec_read_end,
    output bmp_data_wr_en,
    output [23:0] bmp_data,
    input pixel_ready,
    output reg load_error
);
    localparam IDLE=0, HEADER=1, CHECK_SIZE=2, CHECK_END=3, CHECK_HEADER=4,
        SCAN_SIZE=5, SCAN_NEXT=6, SCAN_DECIDE=7,
        FIT_START=8, DIVIDE=9, FIT_FINISH=10, WRITE_WAIT=11, WRITE_RELEASE=12,
        SECTOR=13, BYTE_FETCH=14, BYTE_USE=15, ROW_READY=16,
        OUT_FETCH=17, OUT_SEND=18, H_ADVANCE=19, V_ADVANCE=20,
        NEXT_ROW=21, FINISH=22, CHECK_DECIDE=23, FIT_COMPARE=24, FIT_ALIGN=25,
        BG_PREP=26, BG_WAIT=27, BG_SAMPLE_REQ=28, BG_SAMPLE_WAIT=29;
    reg [4:0] state;
    reg header_is_scan;
    reg [9:0] rx_count;
    reg [31:0] idle_wait;
    // Register the SD byte protocol at the reader boundary. This keeps the
    // SD command FSM state and the scaler's wide control cone from becoming
    // one long 100 MHz path after optional background logic is placed.
    reg [7:0] sd_sec_read_data_q;
    reg sd_sec_read_data_valid_q, sd_sec_read_end_q, sd_sec_read_error_q;
    wire receiving = state==HEADER || state==SECTOR;
    wire active = state!=IDLE;
    // Only external waits time out. Compute and row-consumption states may
    // legitimately take many clocks; every accepted output is progress.
    wire waiting = receiving || state==WRITE_WAIT || state==WRITE_RELEASE || state==OUT_SEND;
    // pixel_ready is the write FIFO's full flag, produced by a subtract-and-
    // compare chain inside the vendor FIFO. Feeding it straight into the
    // timeout and next-state cone dragged that vendor chain onto the critical
    // path. The timeout only needs a "the output is still advancing" hint, so
    // it samples a registered copy. The write enable keeps the raw signal, so a
    // late stop can never overrun the FIFO.
    reg pixel_ready_q;
    always @(posedge clk or posedge rst) begin
        if(rst) pixel_ready_q<=1'b0;
        else pixel_ready_q<=pixel_ready;
    end
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sd_sec_read_data_q <= 8'd0;
            sd_sec_read_data_valid_q <= 1'b0;
            sd_sec_read_end_q <= 1'b0;
            sd_sec_read_error_q <= 1'b0;
        end else begin
            sd_sec_read_data_q <= sd_sec_read_data;
            sd_sec_read_data_valid_q <= sd_sec_read_data_valid;
            sd_sec_read_end_q <= sd_sec_read_end;
            sd_sec_read_error_q <= sd_sec_read_error;
        end
    end
    wire progress = (receiving && (sd_sec_read_data_valid_q || sd_sec_read_end_q)) ||
                    (state==WRITE_WAIT && write_req_ack) ||
                    (state==WRITE_RELEASE && !write_req_ack) ||
                    (state==OUT_SEND && pixel_ready_q);
    wire wait_expired = waiting && !progress && idle_wait>=WAIT_TIMEOUT_CYCLES-1;
    wire bad_sector = receiving && sd_sec_read_end_q && !sd_sec_read_error_q &&
        (rx_count+(sd_sec_read_data_valid_q?10'd1:10'd0)!=10'd512);
    wire fail_operation = active && (cancel || sd_sec_read_error_q || wait_expired || bad_sector);
    always @(posedge clk or posedge rst) begin
        if(rst) idle_wait<=0;
        else if(!waiting || progress) idle_wait<=0;
        else if(idle_wait<WAIT_TIMEOUT_CYCLES) idle_wait<=idle_wait+1'b1;
    end
    // fail_operation 打一拍再进状态机（2026-10-26）。
    // 原来它直接作为主状态机 else-if 分支的条件，于是它必然出现在本模块几乎
    // 每个寄存器的 .ce 项里；而它的一项 wait_expired 是 idle_wait 与
    // WAIT_TIMEOUT_CYCLES-1 的比较，32 位被映射成 16 级进位链。结果是这条
    // 进位链串进了整块寄存器的时钟使能树 —— TD 报告的最差 10 条建立路径
    // 全部从 idle_wait_reg[1] 出发、落在各 xxx_reg.ce 上（SWNS 0.123ns，
    // 数据路径 9.597ns 里 6.668ns 是布线）。
    // 打一拍后 ce 树只看见触发器输出，进位链只驱动 fail_q 的 D 端。
    // fail_q 晚 1 个时钟（100 MHz 下 10ns）才把状态机拉回 IDLE，对外不可见：
    // abort_sd 是电平、load_error/scan_done 是持久标志、bmp_data_wr_en 仍用
    // 组合的 fail_operation（写侧不能再晚）。
    // error_code 的原因在判定当拍锁存到 fail_cause_q，避免一拍后
    // sd_sec_read_error_q / bad_sector 已经撤销而把编码判错。
    reg fail_q;
    reg [2:0] fail_cause_q;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            fail_q <= 1'b0;
            fail_cause_q <= 3'd0;
        end else begin
            fail_q <= fail_operation;
            if (fail_operation)
                fail_cause_q <= sd_sec_read_error_q?3'd1:bad_sector?3'd4:3'd3;
        end
    end
    reg [8:0] proc_pos;
    reg [31:0] scan_sector, load_base, next_sector, file_sectors;
    reg scan_match;
    reg [7:0] signature0, signature1;
    reg [31:0] file_len, pixel_offset, width, height, dib_size, compression;
    reg [15:0] planes, bpp;
    reg [13:0] row_bytes, stride, stride_m1;
    reg [31:0] pixel_end;
    // The header validity decision is deliberately split across the four check
    // states instead of one long expression. Each term is a wide (32-bit)
    // comparison against a header field, and folding them all into a single
    // net serialised the adders and carry chains into a ~9.9 ns path on the
    // 100 MHz SD clock. Staging them costs three clocks per candidate and only
    // runs once per header, never in the pixel path.
    reg hdr_ok_a, hdr_ok_b, hdr_ok_c;
    reg [31:0] pixel_offset_min;
    wire hdr_fields_ok = signature0==8'h42 && signature1==8'h4d &&
        dib_size>=40 && dib_size<=124 &&
        planes==1 && bpp==24 && compression==0;
    wire hdr_dims_ok = width>0 && width<=MAX_WIDTH &&
        height>0 && height<=MAX_HEIGHT && pixel_offset>=pixel_offset_min;
    wire hdr_len_ok = file_len>=pixel_end && pixel_end>pixel_offset;

    reg [7:0] sector_buf[0:511];
    reg [7:0] sector_q;
    reg [23:0] row_buf[0:MAX_WIDTH-1];
    reg [23:0] row_q;

    // 24 位足够，且是可证明的上界：payload_left 只由 pixel_end-pixel_offset 装载，
    // 而 pixel_end-pixel_offset 恒等于 stride*height ≤ 6144*1536 = 9,437,184 < 2^24
    // （stride 由 MAX_WIDTH*3 取整到 4 字节，height ≤ MAX_HEIGHT）。减法按模 2^24
    // 计算与 32 位结果低 24 位完全相同，递减/归零判定也不受影响，省 8 条进位链。
    reg [23:0] payload_left;
    // payload_left 递减到零的时刻原来在 ROW_READY 里现算：32 位归约比较直接
    // 串进 blur 的 finish -> state 次态锥，是 sd_card_clk 域最差的一条路径
    // （9.750ns，逻辑 10 级）。这里与 payload_left 同拍维护零标志，四个赋值点
    // 一起更新，判定结果与 payload_left==0 逐位相同。
    reg payload_zero_q;
    reg first_sector, sector_exhausted;
    reg [13:0] row_byte;
    // A source byte is fetched one cycle before BYTE_USE. Capture its payload
    // predicate there too, so the 14-bit row comparison does not feed the
    // background helper's acceptance/average-control cone in the same cycle.
    // row_byte/row_bytes do not change between FETCH and USE or while USE stalls.
    reg row_has_pixel_q;
    reg [15:0] source_x, source_y;
    reg [1:0] channel;
    reg [7:0] blue, green;
    reg [15:0] fit_w, fit_h, off_x, bottom_rows;
    // 内容区上边界是整帧常量（off_x+fit_w、bottom_rows+fit_h），原来每像素重新
    // 相加，4 个加法器串进 bmp_data 的选择锥，构成 top_adc 的建立时序违例。
    // 预先存成寄存器后比较只剩两个比较器，行为逐位相同。
    reg [15:0] content_x_hi, content_y_hi;
    reg fit_width_limited;
    reg [15:0] out_x, out_y, content_y;
    reg [15:0] sample_x, sample_y;
    reg [16:0] h_rem, v_rem;
    // pass_mode: 0 = legacy single pass, 1 = background ingest pass,
    // 2 = foreground/output pass after the background is complete.
    reg [1:0] pass_mode;
    reg bg_enabled;
    reg bg_start_reg;
    reg bg_cancel_reg;
    reg [23:0] bg_pixel_q;
    // A shared restoring divider runs once per image, never in the pixel
    // path. Explicit operands and one subtract per clock bound timing.
    //
    // 2026-10-27：位宽按可证明的取值域收紧，原来是 32/32/32 + 33 位比较减法跑 32 拍。
    //   被除数 div_bits = div_prod + div_half ≤ MAX_HEIGHT*DST_WIDTH + 1024
    //                    = 1536*640 + 1024 = 984,064 < 2^21  → 21 位
    //   除数   div_den = width 或 height ≤ MAX_WIDTH = 2048       → 12 位
    //   余数   div_rem <  div_den ≤ 2047                          → 12 位
    //   商     = div_bits/div_den ≤ 984,576，21 拍后正好落在 div_bits[20:0]，
    //          下游只取 div_bits[15:0] 与 div_bits==0，与 32 拍版本逐位相同
    // （已用模型穷举：2048 个除数 × 9 个被除数边界 + 30 万随机组 + 除零防御，全等）
    reg [20:0] div_bits;
    reg [11:0] div_rem, div_den;
    reg [4:0] div_count;
    // The dividend is dimension x DST_OTHER plus a rounding half. The multiply
    // and the add are registered separately: a MULT18 feeding a 22-bit carry
    // chain in one 100 MHz cycle was the failing setup path of this reader.
    reg [21:0] div_prod;
    reg [11:0] div_half;
    wire [12:0] div_trial = {div_rem, div_bits[20]};
    wire div_ge = div_trial >= {1'b0,div_den};
    wire [12:0] div_sub = div_trial - {1'b0,div_den};
    wire in_content_x = out_x>=off_x && out_x<content_x_hi;
    wire in_content_y = out_y>=bottom_rows && out_y<content_y_hi;
    wire bg_pixel_valid = (pass_mode==1) && (state==BYTE_USE) &&
                          row_has_pixel_q && (channel==2);
    wire bg_finish = (pass_mode==1) && (state==ROW_READY) &&
                     payload_zero_q;
    wire bg_sample_req = (state==BG_SAMPLE_REQ);
    wire bg_ingest_ready;
    wire bg_done;
    wire bg_sample_valid;
    wire [23:0] bg_sample_rgb;
    assign ready = state==IDLE;
    assign bmp_data_wr_en = state==OUT_SEND && pixel_ready && !fail_operation;
    assign bmp_data = (in_content_x && in_content_y) ? row_q :
                      ((bg_enabled && bg_done) ? bg_pixel_q : 24'h102030);

    generate if (BLUR_BACKGROUND) begin : g_blur_background
        bmp_blur_background #(
            .DST_WIDTH(DST_WIDTH), .DST_HEIGHT(DST_HEIGHT),
            .BRIGHTNESS_NUM(BG_BRIGHTNESS_NUM),
            .BRIGHTNESS_SHIFT(BG_BRIGHTNESS_SHIFT)
        ) u_bg (
            .clk(clk), .rst(rst),
            .cancel(cancel || bg_cancel_reg || !sd_init_done), .start(bg_start_reg),
            .width(width[11:0]), .height(height[10:0]),
            .ingest_ready(bg_ingest_ready), .pixel_valid(bg_pixel_valid),
            .pixel_rgb({sector_q,green,blue}),
            .pixel_x(source_x[11:0]), .pixel_y(source_y[10:0]),
            .finish(bg_finish), .done(bg_done),
            .sample_req(bg_sample_req), .sample_x(out_x), .sample_y(out_y),
            .sample_valid(bg_sample_valid), .sample_rgb(bg_sample_rgb)
        );
    end else begin : g_no_blur_background
        assign bg_ingest_ready = 1'b0;
        assign bg_done = 1'b0;
        assign bg_sample_valid = 1'b0;
        assign bg_sample_rgb = 24'd0;
    end endgenerate

    // Synchronous reads infer block RAM. RAM contents need no reset: only
    // complete received sectors/rows are ever made visible to the consumer.
    always @(posedge clk or posedge rst) begin
        if (rst) row_has_pixel_q<=1'b0;
        else if (state==BYTE_FETCH) row_has_pixel_q<=row_byte<row_bytes;
    end
    always @(posedge clk) begin
        if (state==SECTOR && sd_sec_read_data_valid_q && rx_count<512)
            sector_buf[rx_count[8:0]] <= sd_sec_read_data_q;
        if (state==BYTE_FETCH) sector_q <= sector_buf[proc_pos];
        if (state==OUT_FETCH) row_q <= row_buf[sample_x[10:0]];
        if (state==BYTE_USE && row_has_pixel_q && channel==2)
            row_buf[source_x[10:0]] <= {sector_q, green, blue};
    end


    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state<=IDLE; state_code<=0; header_is_scan<=0;
            abort_sd<=0; operation_error<=0; error_code<=0;
            rx_count<=0; proc_pos<=0; scan_sector<=0; load_base<=0;
            next_sector<=0; file_sectors<=0; scan_match<=0;
            signature0<=0; signature1<=0; file_len<=0; pixel_offset<=0;
            width<=0; height<=0; dib_size<=0; compression<=0; planes<=0; bpp<=0;
            row_bytes<=0; stride<=0; stride_m1<=0; pixel_end<=0; payload_left<=0;
            payload_zero_q<=0;
            hdr_ok_a<=0; hdr_ok_b<=0; hdr_ok_c<=0; pixel_offset_min<=0;
            first_sector<=0; sector_exhausted<=0; row_byte<=0;
            source_x<=0; source_y<=0; channel<=0; blue<=0; green<=0;
            fit_w<=0; fit_h<=0; off_x<=0; bottom_rows<=0; fit_width_limited<=0;
            content_x_hi<=0; content_y_hi<=0;
            out_x<=0; out_y<=0; content_y<=0; sample_x<=0; sample_y<=0;
            h_rem<=0; v_rem<=0; div_bits<=0; div_rem<=0; div_den<=1; div_count<=0;
            div_prod<=0; div_half<=0;
            pass_mode<=0; bg_enabled<=0; bg_start_reg<=0; bg_cancel_reg<=0; bg_pixel_q<=0;
            scan_done<=0; scan_found_valid<=0; scan_found_sector<=0; scan_found_total<=0;
            write_req<=0; sd_sec_read<=0; sd_sec_read_addr<=0; load_error<=0;
        end else if (!sd_init_done) begin
            bg_start_reg<=0; bg_cancel_reg<=0; bg_enabled<=0; pass_mode<=0;
            state<=IDLE; state_code<=0; scan_done<=0; scan_found_valid<=0;
            abort_sd<=0; operation_error<=active; error_code<=active?3'd1:error_code;
            scan_found_total<=0; write_req<=0; sd_sec_read<=0; load_error<=0;
        end else if(fail_q) begin
            bg_start_reg<=0; bg_cancel_reg<=1'b1; bg_enabled<=0; pass_mode<=0;
            state<=IDLE; state_code<=4'he;
            sd_sec_read<=0; write_req<=0; scan_found_valid<=0; scan_done<=1;
            load_error<=1; abort_sd<=(fail_cause_q!=3'd1); operation_error<=1;
            error_code<=fail_cause_q;
        end else begin
            bg_start_reg<=1'b0; bg_cancel_reg<=1'b0;
            abort_sd<=0; operation_error<=0;
            scan_found_valid<=0;
            case(state)
                IDLE: begin
                    state_code<=1; sd_sec_read<=0;
                    if (scan_start || load_start) begin
                        rx_count<=0; load_error<=0;
                        signature0<=0; signature1<=0; file_len<=0;
                        pixel_offset<=0; width<=0; height<=0;
                        dib_size<=0; planes<=0; bpp<=0; compression<=0;
                        header_is_scan<=scan_start;
                        if(scan_start) begin
                            scan_done<=0; scan_found_total<=0;
                            scan_sector<=scan_start_sector;
                            sd_sec_read_addr<=scan_start_sector;
                        end else begin
                            load_base<=load_sector; sd_sec_read_addr<=load_sector;
                        end
                        state<=HEADER;
                    end
                end
                HEADER: begin
                    state_code<=2; if(sd_sec_ready) sd_sec_read<=1;
                    if (sd_sec_read_data_valid_q) begin
                        case(rx_count)
                            0: signature0<=sd_sec_read_data_q;
                            1: signature1<=sd_sec_read_data_q;
                            2: file_len[7:0]<=sd_sec_read_data_q;
                            3: file_len[15:8]<=sd_sec_read_data_q;
                            4: file_len[23:16]<=sd_sec_read_data_q;
                            5: file_len[31:24]<=sd_sec_read_data_q;
                            10: pixel_offset[7:0]<=sd_sec_read_data_q;
                            11: pixel_offset[15:8]<=sd_sec_read_data_q;
                            12: pixel_offset[23:16]<=sd_sec_read_data_q;
                            13: pixel_offset[31:24]<=sd_sec_read_data_q;
                            14: dib_size[7:0]<=sd_sec_read_data_q;
                            15: dib_size[15:8]<=sd_sec_read_data_q;
                            16: dib_size[23:16]<=sd_sec_read_data_q;
                            17: dib_size[31:24]<=sd_sec_read_data_q;
                            18: width[7:0]<=sd_sec_read_data_q;
                            19: width[15:8]<=sd_sec_read_data_q;
                            20: width[23:16]<=sd_sec_read_data_q;
                            21: width[31:24]<=sd_sec_read_data_q;
                            22: height[7:0]<=sd_sec_read_data_q;
                            23: height[15:8]<=sd_sec_read_data_q;
                            24: height[23:16]<=sd_sec_read_data_q;
                            25: height[31:24]<=sd_sec_read_data_q;
                            26: planes[7:0]<=sd_sec_read_data_q;
                            27: planes[15:8]<=sd_sec_read_data_q;
                            28: bpp[7:0]<=sd_sec_read_data_q;
                            29: bpp[15:8]<=sd_sec_read_data_q;
                            30: compression[7:0]<=sd_sec_read_data_q;
                            31: compression[15:8]<=sd_sec_read_data_q;
                            32: compression[23:16]<=sd_sec_read_data_q;
                            33: compression[31:24]<=sd_sec_read_data_q;
                            default: ;
                        endcase
                        rx_count<=rx_count+1'b1;
                    end
                    if(sd_sec_read_end_q) begin
                        sd_sec_read<=0; state<=CHECK_SIZE;
                    end
                end
                CHECK_SIZE: begin
                    // Dimensions are range checked before using truncated
                    // operands; invalid candidates cannot become catalogue entries.
                    row_bytes<=width[11:0]*14'd3;
                    stride<=(width[11:0]*14'd3+14'd3)&14'h3ffc;
                    // Compare against stride-1 in the byte loop instead of
                    // testing row_byte+1==stride, so the 14-bit carry chain is
                    // not in series with the row-end decision on the 100 MHz
                    // byte path.
                    // stride_m1 is prepared in CHECK_END from registered
                    // stride, so multiplication/alignment and subtraction
                    // do not share the same 100 MHz setup path.
                    hdr_ok_a<=hdr_fields_ok; pixel_offset_min<=dib_size+14;
                    state<=CHECK_END;
                end
                CHECK_END: begin
                    stride_m1<=stride-14'd1;
                    pixel_end<=pixel_offset + stride * height[10:0];
                    hdr_ok_b<=hdr_ok_a && hdr_dims_ok;
                    state<=CHECK_HEADER;
                end
                CHECK_HEADER: begin
                    hdr_ok_c<=hdr_ok_b && hdr_len_ok;
                    state<=CHECK_DECIDE;
                end
                CHECK_DECIDE: begin
                    if(header_is_scan) begin scan_match<=hdr_ok_c; state<=SCAN_SIZE; end
                    else if(hdr_ok_c) state<=FIT_COMPARE;
                    else begin load_error<=1; operation_error<=1; error_code<=3'd2; state_code<=4'he; state<=IDLE; end
                end
                SCAN_SIZE: begin
                    file_sectors <= (file_len>>9) + (|file_len[8:0]);
                    state<=SCAN_NEXT;
                end
                SCAN_NEXT: begin
                    next_sector<=scan_sector+(scan_match?file_sectors:32'd1);
                    state<=SCAN_DECIDE;
                end
                SCAN_DECIDE: begin
                    if(scan_match) begin
                        scan_found_valid<=1; scan_found_sector<=scan_sector;
                        scan_found_total<=scan_found_total+1'b1;
                    end
                    if((scan_match && scan_found_total+1'b1>=scan_target_count) ||
                       scan_sector>=scan_max_sector || next_sector>scan_max_sector ||
                       next_sector<=scan_sector) begin
                        scan_done<=1; state<=IDLE;
                    end else begin
                        scan_sector<=next_sector; sd_sec_read_addr<=next_sector;
                        rx_count<=0; state<=HEADER;
                    end
                end
                // Compare cross products, then divide only the unconstrained
                // dimension. A minimum of one pixel handles extreme aspects.
                // The comparison runs in its own state: two multipliers plus a
                // 22-bit compare in series with the destination register enables
                // was the worst path on the 100 MHz SD clock. For the same
                // reason the dividend multiply (FIT_START) and its rounding add
                // (FIT_ALIGN) are separate states; the divider only starts one
                // clock later and the result is unchanged.
                FIT_COMPARE: begin
                    fit_width_limited <= width[11:0]*DST_HEIGHT >= height[10:0]*DST_WIDTH;
                    state<=FIT_START;
                end
                FIT_START: begin
                    if(fit_width_limited) begin
                        fit_w<=DST_WIDTH; div_prod<=height[10:0]*DST_WIDTH;
                        div_half<=(width>>1); div_den<=width;
                    end else begin
                        fit_h<=DST_HEIGHT; div_prod<=width[11:0]*DST_HEIGHT;
                        div_half<=(height>>1); div_den<=height;
                    end
                    state<=FIT_ALIGN;
                end
                FIT_ALIGN: begin
                    div_bits<=div_prod[20:0]+div_half;
                    div_rem<=0; div_count<=21; state<=DIVIDE;
                end
                DIVIDE: begin
                    div_bits<={div_bits[19:0],div_ge};
                    div_rem<=div_ge?div_sub[11:0]:div_trial[11:0];
                    div_count<=div_count-1'b1;
                    if(div_count==1) state<=FIT_FINISH;
                end
                FIT_FINISH: begin
                    if(fit_width_limited) begin
                        fit_h<=div_bits==0?1:div_bits[15:0];
                        bottom_rows<=(DST_HEIGHT-(div_bits==0?1:div_bits[15:0])+1)>>1;
                        off_x<=0;
                        content_x_hi<=DST_WIDTH;
                        content_y_hi<=((DST_HEIGHT-(div_bits==0?1:div_bits[15:0])+1)>>1)
                                      + (div_bits==0?1:div_bits[15:0]);
                    end else begin
                        fit_w<=div_bits==0?1:div_bits[15:0];
                        off_x<=(DST_WIDTH-(div_bits==0?1:div_bits[15:0]))>>1;
                        bottom_rows<=0;
                        content_x_hi<=((DST_WIDTH-(div_bits==0?1:div_bits[15:0]))>>1)
                                      + (div_bits==0?1:div_bits[15:0]);
                        content_y_hi<=DST_HEIGHT;
                    end
                    // A background-enabled load is prepared by a complete
                    // source pass before the SDRAM writer is opened.  If the
                    // contain result fills the whole destination, preserve
                    // the validated one-pass path byte-for-byte.
                    if (fit_width_limited) begin
                        bg_enabled <= BLUR_BACKGROUND &&
                            ((div_bits==0 ? 1 : div_bits[15:0]) != DST_HEIGHT);
                    end else begin
                        bg_enabled <= BLUR_BACKGROUND &&
                            ((div_bits==0 ? 1 : div_bits[15:0]) != DST_WIDTH);
                    end
                    if (BLUR_BACKGROUND &&
                        ((fit_width_limited &&
                          ((div_bits==0 ? 1 : div_bits[15:0]) != DST_HEIGHT)) ||
                         (!fit_width_limited &&
                          ((div_bits==0 ? 1 : div_bits[15:0]) != DST_WIDTH)))) begin
                        pass_mode<=1; bg_start_reg<=1'b1; state<=BG_PREP;
                    end else begin
                        pass_mode<=0; write_req<=1; state<=WRITE_WAIT;
                    end
                end
                BG_PREP: begin
                    // Wait for the thumbnail accumulator to finish its clear
                    // phase before opening the first SD source pass.
                    if (bg_ingest_ready) begin
                        rx_count<=0; first_sector<=1;
                        sd_sec_read_addr<=load_base+(pixel_offset>>9);
                        payload_left<=pixel_end[23:0]-pixel_offset[23:0];
                        payload_zero_q<=(pixel_end==pixel_offset);
                        row_byte<=0; source_x<=0; source_y<=0; channel<=0;
                        state<=SECTOR;
                    end
                end
                BG_WAIT: begin
                    // The helper owns the thumbnail and blur RAM while this
                    // reader waits. No frame write request exists yet.
                    if (bg_done) begin
                        pass_mode<=2; write_req<=1; state<=WRITE_WAIT;
                    end
                end
                WRITE_WAIT: begin
                    state_code<=3;
                    if(write_req_ack) begin
                        write_req<=0; state<=WRITE_RELEASE;
                        rx_count<=0; first_sector<=1;
                        sd_sec_read_addr<=load_base+(pixel_offset>>9);
                        payload_left<=pixel_end[23:0]-pixel_offset[23:0];
                        payload_zero_q<=(pixel_end==pixel_offset);
                        row_byte<=0; source_x<=0; source_y<=0; channel<=0;
                        out_x<=0; out_y<=0; content_y<=0;
                        sample_x<=0; sample_y<=0; h_rem<=0; v_rem<=0;
                    end
                end
                WRITE_RELEASE: begin
                    // ACK is held while the writer clears its FIFO. Do not
                    // produce pixels before its synchronized deassertion.
                    if(!write_req_ack) state<=SECTOR;
                end
                SECTOR: begin
                    state_code<=4; if(sd_sec_ready) sd_sec_read<=1;
                    if(sd_sec_read_data_valid_q) rx_count<=rx_count+1'b1;
                    if(sd_sec_read_end_q) begin
                        sd_sec_read<=0; rx_count<=0;
                        if(rx_count+(sd_sec_read_data_valid_q?10'd1:10'd0)!=512) begin load_error<=1; operation_error<=1; error_code<=3'd4; state<=IDLE; end
                        else begin
                            proc_pos<=first_sector?pixel_offset[8:0]:9'd0;
                            first_sector<=0; state<=BYTE_FETCH;
                        end
                    end
                end
                BYTE_FETCH: state<=BYTE_USE;
                BYTE_USE: begin
                    // The background ingest interface may pause at a source
                    // pixel while it folds a thumbnail row. Hold the SD byte,
                    // channel and source coordinates until it is ready.
                    if (pass_mode==1 && channel==2 && !bg_ingest_ready) begin
                        state<=BYTE_USE;
                    end else begin
                    if(row_has_pixel_q) begin
                        case(channel)
                            0: blue<=sector_q;
                            1: green<=sector_q;
                            2: source_x<=source_x+1'b1;
                        endcase
                        channel<=channel==2?0:channel+1'b1;
                    end
                    payload_left<=payload_left-1'b1;
                    payload_zero_q<=(payload_left==24'd1);
                    proc_pos<=proc_pos+1'b1;
                    sector_exhausted<=proc_pos==511;
                    if(row_byte==stride_m1) begin
                        row_byte<=0; source_x<=0; channel<=0; state<=ROW_READY;
                    end else begin
                        row_byte<=row_byte+1'b1;
                        if(proc_pos==511) begin
                            sd_sec_read_addr<=sd_sec_read_addr+1'b1; state<=SECTOR;
                        end else state<=BYTE_FETCH;
                    end
                    end
                end
                ROW_READY: begin
                    if (pass_mode==1) begin
                        if (payload_zero_q) state<=BG_WAIT;
                        else state<=NEXT_ROW;
                    end else if(out_y<bottom_rows || content_y==fit_h ||
                       (content_y<fit_h && sample_y==source_y))
                        state<=OUT_FETCH;
                    else state<=NEXT_ROW;
                end
                OUT_FETCH: begin
                    if (bg_enabled && bg_done &&
                        !(in_content_x && in_content_y))
                        state<=BG_SAMPLE_REQ;
                    else state<=OUT_SEND;
                end
                BG_SAMPLE_REQ: state<=BG_SAMPLE_WAIT;
                BG_SAMPLE_WAIT: begin
                    if (bg_sample_valid) begin
                        bg_pixel_q<=bg_sample_rgb;
                        state<=OUT_SEND;
                    end
                end
                OUT_SEND: if(pixel_ready) begin
                    if(out_x==DST_WIDTH-1) begin
                        out_x<=0; out_y<=out_y+1'b1; sample_x<=0; h_rem<=0;
                        if(out_y==DST_HEIGHT-1) state<=FINISH;
                        else if(in_content_y) begin
                            content_y<=content_y+1'b1;
                            v_rem<=v_rem+height[15:0]; state<=V_ADVANCE;
                        end else state<=ROW_READY;
                    end else begin
                        out_x<=out_x+1'b1;
                        if(in_content_x && in_content_y) begin
                            h_rem<=h_rem+width[15:0]; state<=H_ADVANCE;
                        end else state<=OUT_FETCH;
                    end
                end
                H_ADVANCE: begin
                    if(h_rem>=fit_w) begin
                        h_rem<=h_rem-fit_w; sample_x<=sample_x+1'b1;
                    end else state<=OUT_FETCH;
                end
                V_ADVANCE: begin
                    if(v_rem>=fit_h) begin
                        v_rem<=v_rem-fit_h; sample_y<=sample_y+1'b1;
                    end else if(content_y==fit_h) state<=OUT_FETCH; // top border
                    else state<=ROW_READY;
                end
                NEXT_ROW: begin
                    source_y<=source_y+1'b1;
                    if(payload_zero_q) begin load_error<=1; operation_error<=1; error_code<=3'd2; state<=IDLE; end
                    else if(sector_exhausted) begin
                        sd_sec_read_addr<=sd_sec_read_addr+1'b1; state<=SECTOR;
                    end else state<=BYTE_FETCH;
                end
                FINISH: begin
                    // ready only rises after the final accepted pixel. The
                    // scheduler independently waits for SDRAM write_finish.
                    state<=IDLE;
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
