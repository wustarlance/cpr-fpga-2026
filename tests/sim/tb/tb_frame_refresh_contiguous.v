`timescale 1ns/1ps
// APUG011: wait before a transaction; an ongoing transaction is contiguous.
// This contract check deliberately changes the refresh indication mid-burst.
module tb_frame_refresh_contiguous;
    reg clk=0, rst=1, refreshing=1, wr_req=0, rd_req=0;
    always #5 clk=~clk;
    wire wr_ack, rd_ack, wr_en, rd_en, wr_busy, rd_busy, urgent;
    wire [20:0] wr_addr, rd_addr;
    integer writes=0, reads=0, wr_words=0, rd_words=0;
    reg wr_active=0, rd_active=0;
    frame_fifo_write #(.BURST_SIZE(128),.WRITE_V_FLIP(1),
        .FRAME_WIDTH(640),.FRAME_HEIGHT(2)) writer(
        .rst(rst),.mem_clk(clk),.Sdr_init_done(!rst),.Sdr_init_ref_vld(refreshing),
        .Sdr_busy(1'b0),.App_rd_busy(rd_busy|urgent),.O_wr_busy(wr_busy),
        .App_wr_en(wr_en),.App_wr_addr(wr_addr),.write_req(wr_req),.write_req_ack(wr_ack),
        .write_finish(),.write_addr_0(21'd0),.write_addr_1(21'd0),.write_addr_2(21'd0),
        .write_addr_3(21'd0),.write_addr_index(2'd0),.write_len(21'd1280),
        .fifo_aclr(),.rdusedw(10'd511));
    frame_fifo_read #(.BURST_SIZE(128),.READ_INDEX_SYNCHRONOUS(1)) reader(
        .rst(rst),.mem_clk(clk),.Sdr_init_done(!rst),.Sdr_init_ref_vld(refreshing),
        .Sdr_busy(1'b0),.Sdr_rd_en(1'b0),.App_wr_busy(wr_busy),.O_rd_busy(rd_busy),
        .App_rd_en(rd_en),.App_rd_addr(rd_addr),.read_req(rd_req),.read_req_ack(rd_ack),
        .read_finish(),.read_addr_0(21'd0),.read_addr_1(21'd0),.read_addr_2(21'd0),
        .read_addr_3(21'd0),.read_addr_index(2'd0),.read_len(21'd1280),
        .fifo_aclr(),.wrusedw(10'd0),.frame_start(),.read_urgent(urgent));
    always @(posedge clk) begin
        if(rst) begin
            writes=0; reads=0; wr_words=0; rd_words=0; wr_active=0; rd_active=0;
        end else begin
            if(wr_en && rd_en) $fatal(1,"read/write overlap");
            if(wr_active && !wr_en) $fatal(1,"write burst interrupted at word %0d",wr_words);
            if(rd_active && !rd_en) $fatal(1,"read burst interrupted at word %0d",rd_words);
            if(wr_en) begin
                if(!wr_active && refreshing) $fatal(1,"write started during refresh");
                if(wr_addr!==((writes<640)?640+writes:writes-640)) $fatal(1,"write address lost");
                writes=writes+1;
                if(wr_words==127) begin wr_words=0; wr_active=0; end
                else begin wr_words=wr_words+1; wr_active=1; end
            end
            if(rd_en) begin
                if(!rd_active && refreshing) $fatal(1,"read started during refresh");
                if(rd_addr!==reads) $fatal(1,"read address lost");
                reads=reads+1;
                if(rd_words==127) begin rd_words=0; rd_active=0; end
                else begin rd_words=rd_words+1; rd_active=1; end
            end
        end
    end
    integer before_count;
    initial begin
        repeat(4) @(negedge clk); rst=0;
        @(negedge clk); rd_req=1; wait(rd_ack);
        @(negedge clk); rd_req=0;
        repeat(20) @(negedge clk);
        if(reads) $fatal(1,"reader escaped initial refresh");
        refreshing=0;
        wait(rd_en); repeat(7) @(negedge clk);
        refreshing=1;
        repeat(160) @(negedge clk);
        if(reads!=128) $fatal(1,"expected exactly one completed read burst, got %0d",reads);
        refreshing=0; wait(reads==1280);
        repeat(20) @(negedge clk);
        // Repeat in the writer without reader arbitration masking the failure.
        rst=1; refreshing=1; wr_req=0; rd_req=0;
        repeat(4) @(negedge clk); rst=0;
        @(negedge clk); wr_req=1; wait(wr_ack);
        @(negedge clk); wr_req=0;
        repeat(20) @(negedge clk);
        if(writes) $fatal(1,"writer escaped initial refresh");
        refreshing=0;
        wait(wr_en); repeat(7) @(negedge clk);
        refreshing=1;
        repeat(160) @(negedge clk);
        if(writes!=128) $fatal(1,"expected exactly one completed write burst, got %0d",writes);
        refreshing=0; wait(writes==1280);
        repeat(20) @(negedge clk);
        if(reads || writes!=1280) $fatal(1,"bad writer totals");
        $display("PASS: tb_frame_refresh_contiguous complete active bursts, block following bursts, preserve addresses");
        $finish;
    end
    initial begin #100000; $fatal(1,"contiguous refresh timeout"); end
endmodule
