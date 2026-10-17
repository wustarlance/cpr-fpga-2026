`timescale 1ns/1ps
// Exercise the actual memory request FSMs. The controller owns refresh and
// does not accept a new user transaction while init_ref_vld is asserted.
module tb_frame_refresh_interlock;
    reg clk=0, rst=1, init_done=0, refreshing=1;
    always #5 clk=~clk;
    reg wr_req=0, rd_req=0;
    wire wr_ack, rd_ack, wr_en, rd_en, wr_finish, rd_finish;
    wire [20:0] wr_addr, rd_addr;
    wire wr_busy, rd_busy, urgent;
    integer writes=0, reads=0, held=0, i;
    frame_fifo_write #(.BURST_SIZE(128),.WRITE_V_FLIP(1),
        .FRAME_WIDTH(640),.FRAME_HEIGHT(2)) writer(
        .rst(rst),.mem_clk(clk),.Sdr_init_done(init_done),
        .Sdr_init_ref_vld(refreshing),.Sdr_busy(1'b0),.App_rd_busy(rd_busy|urgent),
        .O_wr_busy(wr_busy),.App_wr_en(wr_en),.App_wr_addr(wr_addr),
        .write_req(wr_req),.write_req_ack(wr_ack),.write_finish(wr_finish),
        .write_addr_0(21'd0),.write_addr_1(21'd0),.write_addr_2(21'd0),.write_addr_3(21'd0),
        .write_addr_index(2'd0),.write_len(21'd1280),.fifo_aclr(),.rdusedw(10'd511));
    frame_fifo_read #(.BURST_SIZE(128),.READ_INDEX_SYNCHRONOUS(1)) reader(
        .rst(rst),.mem_clk(clk),.Sdr_init_done(init_done),
        .Sdr_init_ref_vld(refreshing),.Sdr_busy(1'b0),.Sdr_rd_en(1'b0),
        .App_wr_busy(wr_busy),.O_rd_busy(rd_busy),.App_rd_en(rd_en),.App_rd_addr(rd_addr),
        .read_req(rd_req),.read_req_ack(rd_ack),.read_finish(rd_finish),
        .read_addr_0(21'd0),.read_addr_1(21'd0),.read_addr_2(21'd0),.read_addr_3(21'd0),
        .read_addr_index(2'd0),.read_len(21'd1280),.fifo_aclr(),.wrusedw(10'd0),
        .frame_start(),.read_urgent(urgent));
    always @(posedge clk) if(!rst) begin
        if(wr_en && rd_en)$fatal(1,"simultaneous SDRAM read and write");
        if(refreshing && (wr_en || rd_en))
            $fatal(1,"SDRAM request issued during active refresh: wr=%b rd=%b",wr_en,rd_en);
        if(refreshing)held=held+1;
        if(wr_en)begin
            if(wr_addr!==((writes<640)?640+writes:writes-640))
                $fatal(1,"V-flip write address skipped or duplicated count=%0d addr=%0d",writes,wr_addr);
            writes=writes+1;
        end
        if(rd_en)begin
            if(rd_addr!==reads)$fatal(1,"read address skipped or duplicated count=%0d addr=%0d",reads,rd_addr);
            reads=reads+1;
        end
    end
    task start_requests;
        begin
            @(negedge clk); wr_req=1;rd_req=1;
            wait(wr_ack && rd_ack);
            @(negedge clk); wr_req=0;rd_req=0;
        end
    endtask
    initial begin
        repeat(4)@(negedge clk);rst=0;init_done=1;
        start_requests;
        repeat(20)@(negedge clk);
        if(writes || reads)$fatal(1,"refresh gate failed before first burst");
        refreshing=0;
        // Refresh can begin after admission but before the registered first
        // request reaches the controller. It must still suppress the strobe.
        @(negedge clk);refreshing=1;
        repeat(6)@(negedge clk);
        if(writes || reads)$fatal(1,"late refresh escaped the command gate");
        refreshing=0;
        // Interrupt the idle gap after every burst, before the next one starts.
        // The currently issued burst has completed; no in-flight command is
        // revoked. Vary refresh length to avoid testing one fortunate phase.
        for(i=0;i<20;i=i+1)begin
            wait(wr_en || rd_en);
            wait(!wr_en && !rd_en);
            @(negedge clk);refreshing=1;
            repeat(3+i%7)@(negedge clk);
            refreshing=0;
        end
        wait(writes==1280 && reads==1280);
        repeat(30)@(negedge clk);
        if(writes!=1280 || reads!=1280 || held<80)
            $fatal(1,"incorrect totals after refresh waits");
        // Repeat the late-admission window with only the writer active, so
        // read-priority arbitration cannot hide a missing write command gate.
        @(negedge clk);rst=1;wr_req=0;rd_req=0;refreshing=1;writes=0;reads=0;
        repeat(4)@(negedge clk);rst=0;
        @(negedge clk);wr_req=1;wait(wr_ack);
        @(negedge clk);wr_req=0;
        repeat(20)@(negedge clk);
        refreshing=0;
        @(negedge clk);refreshing=1;
        repeat(6)@(negedge clk);
        if(writes || reads)$fatal(1,"late writer refresh escaped command gate");
        refreshing=0;wait(writes==1280);
        repeat(30)@(negedge clk);
        if(writes!=1280 || reads!=0)$fatal(1,"writer-only late refresh lost requests");
        $display("PASS tb_frame_refresh_interlock: refresh and late-command gates, 3840 exact requests, arbitration and V-flip");
        $finish;
    end
    initial begin #200000;$fatal(1,"TIMEOUT refresh interlock writes=%0d reads=%0d",writes,reads);end
endmodule
