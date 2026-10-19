`timescale 1ns/1ps
// Actual frame FSMs and generated vendor FIFOs; ERAM contract model only.
// Write FIFO: show-ahead. Read FIFO: synchronous, not show-ahead.
module tb_frame_roundtrip #(parameter MIXED=0);
    reg mem_clk=0, write_clk=0, video_clk=0, rst=1;
    always #12.5 mem_clk=~mem_clk; // actual 40 MHz memory clock
    always #5 write_clk=~write_clk; // actual 100 MHz producer clock
    always #20 video_clk=~video_clk; // actual 25 MHz consumer clock
    reg write_req=0, write_en=0, read_req=0, read_en=0;
    reg [31:0] write_data=0;
    reg [1:0] write_index=0, read_index=0;
    wire write_ack, read_ack, write_finish, write_ready, rd_en, wr_en;
    wire [20:0] wr_addr, rd_addr;
    wire [31:0] wr_data, read_data;
    reg [9:0] response_pipe=0;
    reg [20:0] address_pipe[0:9];
    reg [31:0] memory[0:5119];
    reg [3:0] refresh_left=0;
    wire refresh = refresh_left != 0;
    wire [3:0] dm;
    integer i, cycle=0, writes=0, reads=0, returns=0, displayed=0;
    reg pending=0;
    reg first_ready=0, all_loaded=0, reading_done=0, reader_active=0;
    integer overlap_writes=0;
    frame_read_write #(.FRAME_WIDTH(640), .FRAME_HEIGHT(2), .READ_INDEX_SYNCHRONOUS(1)) dut(
        .rst(rst), .mem_clk(mem_clk), .Sdr_init_done(!rst), .Sdr_init_ref_vld(refresh), .Sdr_busy(1'b0),
        .App_wr_en(wr_en), .App_wr_addr(wr_addr), .App_wr_din(wr_data), .App_wr_dm(dm),
        .App_rd_en(rd_en), .App_rd_addr(rd_addr), .Sdr_rd_en(response_pipe[9]),
        .Sdr_rd_dout(memory[address_pipe[9]]),
        .write_clk(write_clk), .write_req(write_req), .write_req_ack(write_ack),
        .write_finish(write_finish), .write_addr_0(21'd0), .write_addr_1(21'd1280),
        .write_addr_2(21'd2560), .write_addr_3(21'd3840), .write_addr_index(write_index),
        .write_len(21'd1280), .write_en(write_en), .write_data(write_data), .write_ready(write_ready),
        .read_clk(video_clk), .read_req(read_req), .read_req_ack(read_ack), .read_finish(),
        .read_addr_0(21'd0), .read_addr_1(21'd1280), .read_addr_2(21'd2560), .read_addr_3(21'd3840),
        .read_addr_index(read_index), .read_len(21'd1280), .read_en(read_en), .read_data(read_data), .frame_start());
    function [31:0] oracle;
        input integer address;
        begin oracle = 32'h30509000 ^ (address*32'h01010301); end
    endfunction
    always @(negedge mem_clk) begin
        if(rst) begin refresh_left=0; cycle=0; end
        else begin
            cycle=cycle+1;
            if(refresh_left!=0) refresh_left=refresh_left-1;
            else if(cycle%97==0 && !wr_en && !rd_en) refresh_left=3;
        end
    end
    always @(posedge mem_clk) begin
        if(rst) response_pipe<=0;
        else begin
            response_pipe<={response_pipe[8:0],rd_en};
            address_pipe[0]<=rd_addr;
            for(i=1;i<10;i=i+1) address_pipe[i]<=address_pipe[i-1];
            if(wr_en && rd_en) $fatal(1,"overlapping memory commands");
            if(wr_en && (|response_pipe)) $fatal(1,"writer started before read responses drained");
            if(wr_en && reader_active) overlap_writes=overlap_writes+1;
            if(refresh && (wr_en || rd_en)) $fatal(1,"request during refresh");
            if(wr_en) begin
                if(wr_addr>=5120 || wr_data!==oracle(wr_addr) || dm!=0)
                    $fatal(1,"write addr/data mismatch %0d %h",wr_addr,wr_data);
                memory[wr_addr]<=wr_data; writes=writes+1;
            end
            if(rd_en) reads=reads+1;
            if(response_pipe[9]) returns=returns+1;
        end
    end
    always @(posedge video_clk) begin
        if(rst) begin pending<=0; displayed=0; end
        else begin
            pending<=read_en;
            if(pending) begin
                if(read_data!==oracle(read_index*1280+displayed))
                    $fatal(1,"pixel mismatch slot=%0d pixel=%0d got=%h expected=%h",
                           read_index,displayed,read_data,oracle(read_index*1280+displayed));
                displayed=displayed+1;
            end
        end
    end
    integer slot,p,y,x,stalls=0;
    integer read_slot, repeat_index;
    initial begin
        for(p=0;p<5120;p=p+1) memory[p]=32'hdeadbeef;
        repeat(8) @(negedge write_clk); rst=0;
        for(slot=0;slot<4;slot=slot+1) begin
            @(negedge write_clk); write_index=slot; write_req=1;
            wait(write_ack); @(negedge write_clk); write_req=0;
            wait(!write_ack); repeat(8) @(negedge write_clk);
            p=0;
            while(p<1280) begin
                @(negedge write_clk);
                write_en=write_ready;
                if(write_ready) begin
                    write_data=oracle(slot*1280+(1-p/640)*640+p%640); p=p+1;
                end else stalls=stalls+1;
            end
            @(negedge write_clk); write_en=0;
            wait(write_finish); repeat(8) @(negedge write_clk);
            if(slot==0) first_ready=1;
        end
        if(writes!=5120 || stalls==0) $fatal(1,"writes/backpressure incomplete");
        all_loaded=1;
        wait(reading_done);
        if(reads!=(MIXED ? 10240 : 5120) || returns!=reads) $fatal(1,"lost/extra responses");
        if(MIXED && overlap_writes==0) $fatal(1,"no write/read contention exercised");
        if(MIXED) $display("PASS: tb_frame_mixed_roundtrip 10240 pixels with concurrent background writes and refresh");
        else $display("PASS: tb_frame_roundtrip 5120 exact pixels, four slots, V flip, refresh, actual FIFO latency");
        $finish;
    end
    task read_one_frame;
        input integer index;
        begin
            @(negedge video_clk); read_index=index; read_req=1; displayed=0; reader_active=1;
            wait(read_ack); @(negedge video_clk); read_req=0;
            wait(!read_ack); repeat(100) @(negedge video_clk);
            for(y=0;y<2;y=y+1) begin
                for(x=0;x<640;x=x+1) begin @(negedge video_clk); read_en=1; end
                @(negedge video_clk); read_en=0;
                repeat(160) @(negedge video_clk);
            end
            repeat(4) @(negedge video_clk); reader_active=0;
            if(displayed!=1280) $fatal(1,"not all pixels checked");
        end
    endtask
    initial begin
        if(MIXED) begin
            wait(first_ready);
            for(repeat_index=0;repeat_index<4;repeat_index=repeat_index+1) read_one_frame(0);
        end
        wait(all_loaded);
        for(read_slot=0;read_slot<4;read_slot=read_slot+1) read_one_frame(read_slot);
        reading_done=1;
    end
    initial begin #2000000;
        $fatal(1,"roundtrip timeout slot=%0d writes=%0d reads=%0d p=%0d ws=%0d rs=%0d ack=%b req=%b",
            slot,writes,reads,p,dut.frame_fifo_write_m0.state,dut.frame_fifo_read_m0.state,write_ack,write_req);
    end
endmodule

module tb_frame_mixed_roundtrip;
    tb_frame_roundtrip #(.MIXED(1)) fixture();
endmodule
