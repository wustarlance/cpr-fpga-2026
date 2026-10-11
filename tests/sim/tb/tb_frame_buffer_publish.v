`timescale 1ns/1ps
module tb_frame_buffer_publish;
    reg src_clk=0, mem_clk=0, rst_n=0, publish=0, read_req=0;
    reg [1:0] index=0;
    wire busy, done, frame_start, ack;
    wire [1:0] active_index;
    wire [20:0] address;
    integer completions=0;
    always #5 src_clk=~src_clk;
    always #12.5 mem_clk=~mem_clk;
    frame_buffer_publish dut(src_clk,rst_n,publish,index,busy,done,
                             mem_clk,rst_n,frame_start,active_index);
    frame_fifo_read #(.BURST_SIZE(4),.READ_INDEX_SYNCHRONOUS(1)) reader(
        .rst(!rst_n),.mem_clk(mem_clk),.Sdr_init_done(1'b1),
        .Sdr_init_ref_vld(1'b0),.Sdr_busy(1'b0),.Sdr_rd_en(1'b0),
        .App_wr_busy(1'b0),.O_rd_busy(),.App_rd_en(),.App_rd_addr(address),
        .read_req(read_req),.read_req_ack(ack),.read_finish(),
        .read_addr_0(21'd0),.read_addr_1(21'd307200),
        .read_addr_2(21'd0),.read_addr_3(21'd0),
        .read_addr_index(active_index),.read_len(21'd4),
        .fifo_aclr(),.wrusedw(10'd0),.frame_start(frame_start));
    always @(posedge src_clk) begin
        #1;
        if(rst_n && done) begin
            completions=completions+1;
            if(!ack && address != 307204 && address != 4)
                $fatal(1,"acknowledgement precedes reader address capture");
        end
    end
    task request_publish;
        input [1:0] next_index;
        begin
            @(negedge src_clk);index=next_index;publish=1;
            @(negedge src_clk);publish=0;
            if(!busy) $fatal(1,"publication was not accepted");
        end
    endtask
    task next_frame;
        input [20:0] base;
        integer n;
        begin
            @(negedge src_clk);read_req=1;
            n=0;
            while(!ack) begin @(negedge src_clk);n=n+1;
                if(n>200)$fatal(1,"reader handshake timed out");end
            @(negedge mem_clk);
            if(address !== base) $fatal(1,"reader captured %0d, expected %0d",address,base);
            read_req=0;
            repeat(12)@(negedge src_clk);
        end
    endtask
    initial begin
        repeat(4)@(negedge src_clk);rst_n=1;
        request_publish(1);
        repeat(30)@(negedge src_clk);
        if(done || active_index!=0 || !busy)$fatal(1,"swapped before frame boundary");
        next_frame(307200);
        if(busy || completions!=1)$fatal(1,"first swap did not acknowledge exactly once");
        repeat(60)@(negedge src_clk);
        request_publish(0);
        repeat(20)@(negedge src_clk);
        if(active_index!=1 || completions!=1)$fatal(1,"old buffer released early");
        next_frame(0);
        if(busy || completions!=2)$fatal(1,"second swap did not complete");
        request_publish(1);
        #3 rst_n=0;
        repeat(6)@(negedge src_clk);rst_n=1;
        repeat(30)@(negedge src_clk);
        if(busy || active_index!=0 || completions!=2)$fatal(1,"reset replayed abandoned request");
        request_publish(1);
        repeat(20)@(negedge src_clk);next_frame(307200);
        if(completions!=3)$fatal(1,"reset recovery failed");
        $display("PASS tb_frame_buffer_publish");$finish;
    end
    initial begin #200000; $fatal(1,"TIMEOUT"); end
endmodule
