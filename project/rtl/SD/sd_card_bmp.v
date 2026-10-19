
module sd_card_bmp #(
    parameter [1:0] TRAINING_PAGE_INDEX = 2'd1,
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter integer RETRY_LIMIT       = 1,
    parameter integer LOAD_TIMEOUT_CYCLES = CLK_FREQ_HZ * 3,
    parameter integer READER_TIMEOUT_CYCLES = CLK_FREQ_HZ,
    parameter integer TOKEN_TIMEOUT_CYCLES = CLK_FREQ_HZ / 10,
    parameter integer SPI_TIMEOUT_CYCLES = CLK_FREQ_HZ / 100,
    parameter integer RECOVERY_GUARD_CYCLES = 32,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd4,
    parameter         SCALE_ENABLE     = 1'b0,
    parameter         BLUR_BACKGROUND  = 1'b0,
    parameter integer BG_BRIGHTNESS_NUM = 3,
    parameter integer BG_BRIGHTNESS_SHIFT = 2,
    parameter integer DST_WIDTH        = 640,
    parameter integer DST_HEIGHT       = 480
)(
    input                       clk,
    input                       rst,
    input                       key_next,
    input                       key_prev,
    input                       key_auto,
    input                       external_auto,
    input                       training_active,
    input                       training_next,
    input                       training_prev,
    output [11:0]               page_status,
    output [3:0]                state_code,
    output reg [2:0]            media_error,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output reg                  display_valid,

    input                       write_finish_toggle,
    output reg [1:0]            write_buf_idx,
    output reg [1:0]            disp_buf_idx,
    output reg                  publish_req,
    input                       publish_done,

    output                      write_req,
    input                       write_req_ack,
    input                       pixel_ready,
    output                      write_en,
    output [31:0]               write_data,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO
);

wire key_next_press;
wire key_prev_press;
reg pending_prev;
wire key_auto_press;
reg [1:0] auto_sync;
always @(posedge clk or posedge rst) begin
    if (rst) auto_sync <= 0;
    else auto_sync <= {auto_sync[0],external_auto};
end

wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire [7:0]       sd_sec_read_data;
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire             bmp_data_wr_en;
wire [23:0]      bmp_data;
wire             sd_init_done;
wire             bmp_ready;
wire sd_ready, sd_read_error, abort_sd, operation_error;
wire [2:0] operation_error_code;
wire [3:0] bmp_state_code;
reg cancel_load;
reg recovering, recover_scan, media_fault;
reg [7:0] retry_count;
reg [31:0] recovery_count, load_timer;
reg writer_started;
reg [1:0] write_ack_sync;
wire             scan_done;
wire             scan_found_valid;
wire [31:0]      scan_found_sector;
wire [2:0]       scan_found_total;

reg              scan_start_pulse;
reg              load_start_pulse;
reg [31:0]       load_sector;
reg              scan_kicked;
reg              first_image_committed;
reg              auto_play_en;
reg [31:0]       auto_cnt;
reg [2:0]        img_found_count;
reg [1:0]        img_idx;              // 当前真正显示中的图片编号
reg [1:0]        load_idx;             // 当前正在写入的图片编号
reg [1:0]        pending_buf_idx;      // 当前正在写入的目标缓冲区
reg [31:0]       img_sector0;
reg [31:0]       img_sector1;
reg [31:0]       img_sector2;
reg [31:0]       img_sector3;
reg              next_req_pending;
reg              load_busy;
reg              publish_wait;
// Fixed physical slot n stores logical image n. Full-cache loads never
// overwrite a valid slot; validity is published only after SD and SDRAM finish.
reg [3:0] cache_valid, cache_failed;
reg [2:0] load_seq;
reg auto_key_en;
wire load_error;

// These three inputs are debounced levels from the video clock domain.
reg [1:0] training_sync, train_next_sync, train_prev_sync;
always @(posedge clk or posedge rst) begin
    if (rst) begin training_sync<=0; train_next_sync<=0; train_prev_sync<=0; end
    else begin
        training_sync<={training_sync[0],training_active};
        train_next_sync<={train_next_sync[0],training_next};
        train_prev_sync<={train_prev_sync[0],training_prev};
    end
end
wire page_request, page_pending, page_missing, page_user_request;
wire [1:0] page_index;
assign state_code = media_fault ? 4'he : page_missing ? 4'hd : bmp_state_code;
wire page_accept = page_request && sd_init_done && scan_done &&
    (SCALE_ENABLE ? (!publish_wait && cache_valid[page_index]) :
                   (!recovering && !load_busy && bmp_ready && sd_ready));
cpr_page_manager #(.TRAINING_PAGE_INDEX(TRAINING_PAGE_INDEX)) u_pages(
    .clk(clk), .rst(rst), .training(training_sync[1]),
    .next_level(train_next_sync[1]), .prev_level(train_prev_sync[1]),
    .catalog_ready(scan_done && sd_init_done), .page_count(img_found_count),
    .display_valid(display_valid), .display_index(img_idx),
    .request_accept(page_accept), .request_valid(page_request),
    .request_pending(page_pending), .request_index(page_index),
    .page_missing(page_missing), .user_request(page_user_request));
wire page_loading = load_busy || recovering || (page_pending && !page_missing);
wire [1:0] status_target = page_pending ? page_index : load_busy ? load_idx : img_idx;
// Coherent SD-domain word: valid/current/count/target/loading/missing/error/train.
assign page_status = {display_valid,img_idx,img_found_count,status_target,
                      page_loading,page_missing,media_fault,training_sync[1]};

// bmp_ready 先表示“源文件读取/送 FIFO 完成”；真正切显示要等 write_finish_toggle 同步后
reg              source_done_seen;
reg              source_busy_seen;
reg              write_done_seen;

// 同步 mem_clk 域的 write_finish_toggle
reg [2:0]        wrfin_tgl_sync;
wire             write_finish_pulse;

wire auto_tick;
wire [1:0] next_from_current;
wire [1:0] manual_from_current;

assign write_en   = bmp_data_wr_en && load_busy && !recovering && !operation_error && !cancel_load;
assign write_data = {bmp_data[23:16], bmp_data[15:8], bmp_data[7:0], 8'b0};
assign auto_tick  = (auto_cnt == (CLK_FREQ_HZ - 1));
assign next_from_current = next_index_limited(img_idx, img_found_count);
assign manual_from_current = pending_prev ? prev_index_limited(img_idx, img_found_count) : next_from_current;
assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (20)
) u_key_next (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_next),
    .press_pulse(key_next_press)
);

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (20)
) u_key_auto (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_auto),
    .press_pulse(key_auto_press)
);

key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(20)) u_key_prev(
    .clk         (clk),
    .rst         (rst),
    .button_in   (key_prev),
    .press_pulse (key_prev_press));
function [1:0] prev_index_limited;
    input [1:0] cur;
    input [2:0] count;
    begin
        if (count <= 1) prev_index_limited = 0;
        else if (cur != 0) prev_index_limited = cur - 1'b1;
        else case (count)
            2: prev_index_limited = 1;
            3: prev_index_limited = 2;
            default: prev_index_limited = 3;
        endcase
    end
endfunction
function [1:0] next_index_limited;
    input [1:0] cur;
    input [2:0] count;
    begin
        case (count)
            3'd0: next_index_limited = 2'd0;
            3'd1: next_index_limited = 2'd0;
            3'd2: next_index_limited = (cur == 2'd1) ? 2'd0 : (cur + 2'd1);
            3'd3: next_index_limited = (cur == 2'd2) ? 2'd0 : (cur + 2'd1);
            default: next_index_limited = (cur == 2'd3) ? 2'd0 : (cur + 2'd1);
        endcase
    end
endfunction

function [31:0] sector_lut;
    input [1:0] idx;
    begin
        case (idx)
            2'd0: sector_lut = img_sector0;
            2'd1: sector_lut = img_sector1;
            2'd2: sector_lut = img_sector2;
            2'd3: sector_lut = img_sector3;
            default: sector_lut = img_sector0;
        endcase
    end
endfunction

function [1:0] next_buf_lut;
    input [1:0] cur_disp_buf;
    input       valid_now;
    begin
        if (!valid_now)
            next_buf_lut = 2'd0;                 // 首图固定写 buffer0
        else if (cur_disp_buf == 2'd0)
            next_buf_lut = 2'd1;
        else
            next_buf_lut = 2'd0;
    end
endfunction

// Failure recovery never changes a published/displayed buffer. A retry uses
// the same non-display buffer and performs a fresh writer request/FIFO reset.
wire source_complete = source_done_seen || (source_busy_seen && bmp_ready);
wire writer_complete = write_done_seen || (writer_started && write_finish_pulse);
wire load_expired = load_busy && !publish_wait &&
                    load_timer >= LOAD_TIMEOUT_CYCLES-1 &&
                    !(source_complete && writer_complete);

generate if (!SCALE_ENABLE) begin : g_legacy_scheduler
always @(posedge clk or posedge rst) begin
    if (rst) begin
        wrfin_tgl_sync<=0; write_ack_sync<=0;
        scan_start_pulse<=0; load_start_pulse<=0; cancel_load<=0;
        load_sector<=0; scan_kicked<=0; first_image_committed<=0;
        auto_play_en<=0; auto_cnt<=0; img_found_count<=0;
        img_idx<=0; load_idx<=0; pending_buf_idx<=0;
        write_buf_idx<=0; disp_buf_idx<=0;
        img_sector0<=0; img_sector1<=0; img_sector2<=0; img_sector3<=0;
        next_req_pending<=0; pending_prev<=0;
        load_busy<=0; publish_wait<=0; publish_req<=0;
        source_done_seen<=0; source_busy_seen<=0; write_done_seen<=0;
        display_valid<=0; recovering<=0; recover_scan<=0;
        retry_count<=0; recovery_count<=0; media_fault<=0; media_error<=0;
        writer_started<=0; load_timer<=0;
    end else begin
        wrfin_tgl_sync <= {wrfin_tgl_sync[1:0],write_finish_toggle};
        write_ack_sync <= {write_ack_sync[0],write_req_ack};
        scan_start_pulse<=0; load_start_pulse<=0; cancel_load<=0; publish_req<=0;
        if (!load_busy || publish_wait) load_timer<=0;
        else if (load_timer < LOAD_TIMEOUT_CYCLES) load_timer<=load_timer+1'b1;

        if (!sd_init_done) begin
            scan_kicked<=0; img_found_count<=0; next_req_pending<=0;
            load_busy<=0; publish_wait<=0; source_done_seen<=0;
            source_busy_seen<=0; write_done_seen<=0; writer_started<=0;
            recovering<=0; retry_count<=0; media_fault<=0; media_error<=0;
            auto_cnt<=0; auto_play_en<=0;
        end else if (recovering) begin
            if (recovery_count < RECOVERY_GUARD_CYCLES)
                recovery_count<=recovery_count+1'b1;
            // Drain the cancelled transaction and any previous write ACK first.
            if (recovery_count >= RECOVERY_GUARD_CYCLES && bmp_ready &&
                sd_ready && !write_ack_sync[1]) begin
                recovering<=0;
                if (RETRY_LIMIT >= 0 && RETRY_LIMIT < 255 && retry_count <= RETRY_LIMIT) begin
                    if (recover_scan) begin
                        scan_start_pulse<=1; img_found_count<=0;
                        first_image_committed<=0;
                    end else begin
                        load_start_pulse<=1; load_busy<=1; load_timer<=0;
                        source_done_seen<=0; source_busy_seen<=0;
                        write_done_seen<=0; writer_started<=0;
                    end
                end else begin
                    media_fault<=1;
                    next_req_pending<=0;
                end
            end
        end else if ((load_busy && !publish_wait && operation_error) || load_expired ||
                     (!load_busy && scan_kicked && operation_error)) begin
            recovering<=1;
            recover_scan<=!load_busy;
            recovery_count<=0;
            if (retry_count != 255) retry_count<=retry_count+1'b1;
            media_error<=load_expired ? 3'd3 : operation_error_code;
            cancel_load<=load_expired;
            load_busy<=0; publish_wait<=0;
            source_done_seen<=0; source_busy_seen<=0; write_done_seen<=0;
            writer_started<=0; next_req_pending<=0; auto_cnt<=0;
        end else begin
            if (scan_found_valid && !media_fault) begin
                case (img_found_count)
                    0: img_sector0<=scan_found_sector;
                    1: img_sector1<=scan_found_sector;
                    2: img_sector2<=scan_found_sector;
                    3: img_sector3<=scan_found_sector;
                    default: ;
                endcase
                if (img_found_count<4) img_found_count<=img_found_count+1'b1;
            end
            if (load_busy && !bmp_ready) source_busy_seen<=1;
            if (load_busy && source_busy_seen && bmp_ready) source_done_seen<=1;
            if (load_busy && write_req && write_ack_sync[1]) begin
                writer_started<=1;
                write_done_seen<=0;
            end else if (load_busy && writer_started && write_finish_pulse)
                write_done_seen<=1;

            if (load_busy && !publish_wait && source_complete && writer_complete) begin
                disp_buf_idx<=pending_buf_idx;
                publish_req<=1; publish_wait<=1;
            end
            // Once publication has been sent it is irrevocable. Wait for the
            // existing frame-boundary ACK; never free a possibly active buffer.
            if (load_busy && publish_wait && publish_done) begin
                load_busy<=0; publish_wait<=0;
                source_done_seen<=0; source_busy_seen<=0; write_done_seen<=0;
                writer_started<=0; img_idx<=load_idx; display_valid<=1;
                first_image_committed<=1; retry_count<=0;
                media_fault<=0; media_error<=0;
            end

            // A new managed request may retry a failed load. Scan failures need
            // an explicit new action, rather than endlessly retrying a pending page.
            if (page_user_request && media_fault && (recover_scan || img_found_count==0)) begin
                media_fault<=0; media_error<=0; retry_count<=0; scan_kicked<=0;
            end
            if (training_sync[1] || page_pending) begin
                next_req_pending<=0;
            end else if ((key_next_press || key_prev_press) && media_fault) begin
                media_fault<=0; media_error<=0; retry_count<=0;
                if (recover_scan || img_found_count==0) begin
                    scan_kicked<=0; next_req_pending<=0;
                end else if (display_valid) begin
                    next_req_pending<=1;
                    pending_prev<=key_prev_press && !key_next_press;
                end
            end else if ((key_next_press || key_prev_press) && scan_done && img_found_count>0) begin
                next_req_pending<=1;
                pending_prev<=key_prev_press && !key_next_press;
            end

            auto_play_en<=auto_sync[1] && !training_sync[1] && !page_pending;
            if (scan_done && auto_play_en && !training_sync[1] && !page_pending && display_valid && !load_busy &&
                first_image_committed && img_found_count>1 && !media_fault) begin
                if (auto_tick) auto_cnt<=0;
                else auto_cnt<=auto_cnt+1'b1;
            end else auto_cnt<=0;

            if (!scan_kicked && bmp_ready && sd_ready && !media_fault) begin
                scan_start_pulse<=1; scan_kicked<=1;
                first_image_committed<=0; img_found_count<=0;
                next_req_pending<=0; retry_count<=0;
            end else if (page_accept) begin
                // ACK even if already showing the page; faults require a fresh load.
                next_req_pending<=0; auto_cnt<=0;
                if (!display_valid || img_idx!=page_index || media_fault) begin
                    load_idx<=page_index; load_sector<=sector_lut(page_index);
                    pending_buf_idx<=next_buf_lut(disp_buf_idx,display_valid);
                    write_buf_idx<=next_buf_lut(disp_buf_idx,display_valid);
                    load_start_pulse<=1; load_busy<=1; load_timer<=0;
                    source_done_seen<=0; source_busy_seen<=0; write_done_seen<=0;
                    writer_started<=0; retry_count<=0; media_fault<=0; media_error<=0;
                end
            end else if (!training_sync[1] && !page_pending && !media_fault &&
                         scan_done && bmp_ready && sd_ready && !load_busy) begin
                if (!first_image_committed && img_found_count>0) begin
                    load_idx<=0; load_sector<=img_sector0;
                    pending_buf_idx<=next_buf_lut(disp_buf_idx,display_valid);
                    write_buf_idx<=next_buf_lut(disp_buf_idx,display_valid);
                    load_start_pulse<=1; load_busy<=1; load_timer<=0;
                    source_done_seen<=0; source_busy_seen<=0; write_done_seen<=0;
                    writer_started<=0; next_req_pending<=0; auto_cnt<=0; retry_count<=0;
                end else if (display_valid && img_found_count>0 &&
                             (next_req_pending || (auto_play_en && auto_tick && img_found_count>1))) begin
                    load_idx<=next_req_pending ? manual_from_current : next_from_current;
                    load_sector<=sector_lut(next_req_pending ? manual_from_current : next_from_current);
                    pending_buf_idx<=next_buf_lut(disp_buf_idx,display_valid);
                    write_buf_idx<=next_buf_lut(disp_buf_idx,display_valid);
                    load_start_pulse<=1; load_busy<=1; load_timer<=0;
                    source_done_seen<=0; source_busy_seen<=0; write_done_seen<=0;
                    writer_started<=0; next_req_pending<=0; auto_cnt<=0; retry_count<=0;
                end
            end
        end
    end
end

end else begin : g_cache_scheduler
// Full-cache path retains the PR transport recovery policy but separates
// background loading from frame publication. A corrupt partial slot is never
// valid and cannot be selected by teaching, autoplay or training navigation.
wire [1:0] manual_index = pending_prev ?
    prev_index_limited(img_idx,img_found_count) : next_index_limited(img_idx,img_found_count);
wire [1:0] auto_index = next_index_limited(img_idx,img_found_count);
wire cache_complete = load_busy && source_complete && writer_complete;
wire cache_timeout = load_busy && load_timer >= LOAD_TIMEOUT_CYCLES-1 && !cache_complete;
wire user_scan_retry = page_user_request || key_next_press || key_prev_press;
wire cache_can_load = scan_done && bmp_ready && sd_ready && !load_busy && !recovering;
reg [1:0] target;
reg select_load;
always @* begin
    target=load_seq[1:0]; select_load=0;
    if (page_request && !cache_valid[page_index] && !cache_failed[page_index]) begin
        target=page_index; select_load=1;
    end else if (next_req_pending && !cache_valid[manual_index] && !cache_failed[manual_index]) begin
        target=manual_index; select_load=1;
    end else if (load_seq<img_found_count && load_seq<4) begin
        target=load_seq[1:0];
        select_load=!cache_valid[load_seq[1:0]] && !cache_failed[load_seq[1:0]];
    end
end
always @(posedge clk or posedge rst) begin
    if(rst) begin
        cache_valid<=0; cache_failed<=0; load_seq<=0;
        wrfin_tgl_sync<=0; write_ack_sync<=0;
        scan_start_pulse<=0; load_start_pulse<=0; cancel_load<=0;
        load_sector<=0; scan_kicked<=0; first_image_committed<=0;
        auto_play_en<=0; auto_key_en<=0; auto_cnt<=0; img_found_count<=0;
        img_idx<=0; load_idx<=0; pending_buf_idx<=0;
        write_buf_idx<=0; disp_buf_idx<=0;
        img_sector0<=0; img_sector1<=0; img_sector2<=0; img_sector3<=0;
        next_req_pending<=0; pending_prev<=0;
        load_busy<=0; publish_wait<=0; publish_req<=0;
        source_done_seen<=0; source_busy_seen<=0; write_done_seen<=0;
        display_valid<=0; recovering<=0; recover_scan<=0;
        retry_count<=0; recovery_count<=0; media_fault<=0; media_error<=0;
        writer_started<=0; load_timer<=0;
    end else begin
        wrfin_tgl_sync<={wrfin_tgl_sync[1:0],write_finish_toggle};
        write_ack_sync<={write_ack_sync[0],write_req_ack};
        scan_start_pulse<=0; load_start_pulse<=0; cancel_load<=0; publish_req<=0;
        if(!load_busy) load_timer<=0;
        else if(load_timer<LOAD_TIMEOUT_CYCLES) load_timer<=load_timer+1'b1;
        if(!sd_init_done) begin
            cache_valid<=0; cache_failed<=0; load_seq<=0; img_found_count<=0;
            scan_kicked<=0; load_busy<=0; publish_wait<=0; display_valid<=0;
            source_done_seen<=0; source_busy_seen<=0; write_done_seen<=0;
            writer_started<=0; recovering<=0; retry_count<=0;
            media_fault<=0; media_error<=0; next_req_pending<=0;
            first_image_committed<=0; auto_play_en<=0; auto_key_en<=0; auto_cnt<=0;
        end else begin
            // Publication is independent of load recovery. Once sent, the
            // bundled index remains unchanged until the video-domain ACK.
            if(publish_wait && publish_done) begin
                publish_wait<=0; img_idx<=disp_buf_idx; display_valid<=1;
                first_image_committed<=1; auto_cnt<=0;
            end
            if(!publish_wait) begin
                if(page_accept) begin
                    next_req_pending<=0; auto_cnt<=0;
                    if(!display_valid || img_idx!=page_index) begin
                        disp_buf_idx<=page_index; publish_req<=1; publish_wait<=1;
                    end
                end else if(!page_pending && !training_sync[1]) begin
                    if(!display_valid && |cache_valid) begin
                        if(cache_valid[0]) disp_buf_idx<=0;
                        else if(cache_valid[1]) disp_buf_idx<=1;
                        else if(cache_valid[2]) disp_buf_idx<=2;
                        else disp_buf_idx<=3;
                        publish_req<=1; publish_wait<=1;
                    end else if(display_valid && next_req_pending && cache_valid[manual_index]) begin
                        disp_buf_idx<=manual_index; publish_req<=1; publish_wait<=1;
                        next_req_pending<=0;
                    end else if(display_valid && !next_req_pending && auto_play_en && auto_tick && cache_valid[auto_index]) begin
                        disp_buf_idx<=auto_index; publish_req<=1; publish_wait<=1;
                    end
                end
            end
            if(training_sync[1] || page_pending) next_req_pending<=0;
            else if((key_next_press || key_prev_press) && display_valid) begin
                next_req_pending<=1; pending_prev<=key_prev_press && !key_next_press;
                // A fresh user action can retry the requested failed slot.
                if(key_prev_press && !key_next_press)
                    cache_failed[prev_index_limited(img_idx,img_found_count)]<=0;
                else cache_failed[next_index_limited(img_idx,img_found_count)]<=0;
            end
            if(page_user_request && page_request) cache_failed[page_index]<=0;
            if(key_auto_press) auto_key_en<=!auto_key_en;
            auto_play_en<=(auto_sync[1] || auto_key_en) && !training_sync[1] && !page_pending;
            if(!auto_play_en || !display_valid || training_sync[1] || page_pending) auto_cnt<=0;
            else if(!auto_tick) auto_cnt<=auto_cnt+1'b1;

            if(recovering) begin
                if(recovery_count<RECOVERY_GUARD_CYCLES) recovery_count<=recovery_count+1'b1;
                if(recovery_count>=RECOVERY_GUARD_CYCLES && bmp_ready && sd_ready && !write_ack_sync[1]) begin
                    recovering<=0;
                    if(RETRY_LIMIT>=0 && RETRY_LIMIT<255 && retry_count<=RETRY_LIMIT) begin
                        if(recover_scan) begin
                            scan_start_pulse<=1; img_found_count<=0;
                        end else begin
                            load_start_pulse<=1; load_busy<=1; load_timer<=0;
                            source_done_seen<=0; source_busy_seen<=0;
                            write_done_seen<=0; writer_started<=0;
                        end
                    end else begin
                        media_fault<=1;
                        if(!recover_scan) cache_failed[pending_buf_idx]<=1;
                    end
                end
            end else if((load_busy && operation_error) || cache_timeout ||
                        (!load_busy && scan_kicked && operation_error)) begin
                recovering<=1; recover_scan<=!load_busy; recovery_count<=0;
                if(retry_count!=255) retry_count<=retry_count+1'b1;
                media_error<=cache_timeout?3'd3:operation_error_code;
                cancel_load<=cache_timeout;
                load_busy<=0; source_done_seen<=0; source_busy_seen<=0;
                write_done_seen<=0; writer_started<=0;
                if(load_busy) cache_valid[pending_buf_idx]<=0;
            end else begin
                if(scan_found_valid && img_found_count<4) begin
                    case(img_found_count)
                        0:img_sector0<=scan_found_sector; 1:img_sector1<=scan_found_sector;
                        2:img_sector2<=scan_found_sector; 3:img_sector3<=scan_found_sector;
                    endcase
                    img_found_count<=img_found_count+1'b1;
                end
                if(load_busy && !bmp_ready) source_busy_seen<=1;
                if(load_busy && source_busy_seen && bmp_ready) source_done_seen<=1;
                if(load_busy && write_req && write_ack_sync[1]) begin
                    writer_started<=1; write_done_seen<=0;
                end else if(load_busy && writer_started && write_finish_pulse) write_done_seen<=1;
                if(cache_complete && !load_error) begin
                    cache_valid[pending_buf_idx]<=1; cache_failed[pending_buf_idx]<=0;
                    load_busy<=0; source_done_seen<=0; source_busy_seen<=0;
                    write_done_seen<=0; writer_started<=0; retry_count<=0;
                    media_fault<=0; media_error<=0;
                end
                if(media_fault && recover_scan && user_scan_retry) begin
                    media_fault<=0; media_error<=0; retry_count<=0;
                    scan_kicked<=0; img_found_count<=0; load_seq<=0;
                end else if(!scan_kicked && bmp_ready && sd_ready && !media_fault) begin
                    scan_start_pulse<=1; scan_kicked<=1; img_found_count<=0; retry_count<=0;
                end else if(cache_can_load && !(media_fault && recover_scan)) begin
                    if(select_load) begin
                        // Only invalid slots are selected. A live frame remains
                        // immutable across retries, prefetch and mode changes.
                        write_buf_idx<=target; pending_buf_idx<=target; load_idx<=target;
                        load_sector<=sector_lut(target); load_start_pulse<=1;
                        load_busy<=1; load_timer<=0; retry_count<=0;
                        source_done_seen<=0; source_busy_seen<=0;
                        write_done_seen<=0; writer_started<=0;
                        cache_failed[target]<=0;
                        if({1'b0,target}==load_seq) load_seq<=load_seq+1'b1;
                    end else if(load_seq<img_found_count && load_seq<4 &&
                                (cache_valid[load_seq[1:0]] || cache_failed[load_seq[1:0]]))
                        load_seq<=load_seq+1'b1;
                end
            end
        end
    end
end
end endgenerate

generate if(SCALE_ENABLE) begin : g_scaled_reader
    bmp_read_scaled #(.DST_WIDTH(DST_WIDTH),.DST_HEIGHT(DST_HEIGHT),
        .BLUR_BACKGROUND(BLUR_BACKGROUND),
        .BG_BRIGHTNESS_NUM(BG_BRIGHTNESS_NUM),
        .BG_BRIGHTNESS_SHIFT(BG_BRIGHTNESS_SHIFT),
        .WAIT_TIMEOUT_CYCLES(READER_TIMEOUT_CYCLES)) bmp_read_m0(
        .cancel(cancel_load),.sd_sec_ready(sd_ready),.sd_sec_read_error(sd_read_error),
        .abort_sd(abort_sd),.operation_error(operation_error),.error_code(operation_error_code),
        .clk(clk),.rst(rst),.ready(bmp_ready),
        .scan_start(scan_start_pulse),.scan_start_sector(SCAN_START_SECTOR),
        .scan_max_sector(SCAN_MAX_SECTOR),.scan_target_count(SCAN_TARGET_COUNT>4?3'd4:SCAN_TARGET_COUNT),
        .scan_done(scan_done),.scan_found_valid(scan_found_valid),
        .scan_found_sector(scan_found_sector),.scan_found_total(scan_found_total),
        .load_start(load_start_pulse),.load_sector(load_sector),.sd_init_done(sd_init_done),
        .state_code(bmp_state_code),.bmp_width(bmp_width),.bmp_height(bmp_height),
        .write_req(write_req),.write_req_ack(write_ack_sync[1]),
        .sd_sec_read(sd_sec_read),.sd_sec_read_addr(sd_sec_read_addr),
        .sd_sec_read_data(sd_sec_read_data),.sd_sec_read_data_valid(sd_sec_read_data_valid),
        .sd_sec_read_end(sd_sec_read_end),.bmp_data_wr_en(bmp_data_wr_en),.bmp_data(bmp_data),
        .pixel_ready(pixel_ready),.load_error(load_error));
end else begin : g_legacy_reader
    assign load_error=1'b0;
bmp_read #(.WAIT_TIMEOUT_CYCLES(READER_TIMEOUT_CYCLES)) bmp_read_m0(
    .cancel(cancel_load), .sd_sec_ready(sd_ready),
    .sd_sec_read_error(sd_read_error), .abort_sd(abort_sd),
    .operation_error(operation_error), .error_code(operation_error_code),
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (bmp_ready),

    .scan_start             (scan_start_pulse),
    .scan_start_sector      (SCAN_START_SECTOR),
    .scan_max_sector        (SCAN_MAX_SECTOR),
    .scan_target_count      (SCAN_TARGET_COUNT),
    .scan_done              (scan_done),
    .scan_found_valid       (scan_found_valid),
    .scan_found_sector      (scan_found_sector),
    .scan_found_total       (scan_found_total),

    .load_start             (load_start_pulse),
    .load_sector            (load_sector),

    .sd_init_done           (sd_init_done),
    .state_code             (bmp_state_code),
    .bmp_width              (bmp_width),
    .bmp_height             (bmp_height),
    .write_req              (write_req),
    .write_req_ack          (write_ack_sync[1]),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data)
);

end endgenerate

sd_card_top #(.TOKEN_TIMEOUT_CYCLES(TOKEN_TIMEOUT_CYCLES),
              .SPI_TIMEOUT_CYCLES(SPI_TIMEOUT_CYCLES)) sd_card_top_m0(
    .read_cancel(abort_sd), .sd_sec_ready(sd_ready),
    .sd_sec_read_error(sd_read_error),
    .clk                    (clk),
    .rst                    (rst),
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (8'd0),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

reg button_sync0;
reg button_sync1;
reg button_stable;
reg [31:0] cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        cnt           <= 32'd0;
        press_pulse   <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else begin
            if (cnt >= DEBOUNCE_CYCLES - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                cnt           <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end

endmodule
