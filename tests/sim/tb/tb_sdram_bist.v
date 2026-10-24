`timescale 1ns/1ps
// ERAM behavioral contract only: does not model encrypted controller/physical SDRAM.
module tb_sdram_bist;
    reg clk=0; always #12.5 clk=~clk;
    reg rst=1, init_done=0, refresh=0, short_burst=0;
    wire wr_en, rd_en, done;
    wire [8:0] wr_addr, rd_addr, bad_addr, last_bad;
    wire [31:0] wr_data, expected_data, actual_data;
    wire [31:0] head_map, bad_total, bad_total_2;
    wire [3:0] status;
    wire [1:0] phase, fault;
    reg [9:0] valid_pipe=0;
    reg [8:0] address_pipe[0:9];
    reg [31:0] memory[0:511];
    reg corrupt=0, drop=0, extra=0, shift=0, odd_nb=0;
    wire return_valid = extra || (valid_pipe[9] && !drop);
    // Two wrong-but-plausible accesses, so the mismatch counters are proven to
    // separate them before the board is asked to decide between them.
    wire [8:0] shifted_addr = address_pipe[9] + 9'd1;
    wire [8:0] aliased_addr = {address_pipe[9][8:1], 1'b1};
    wire [31:0] source_word = shift ? memory[shifted_addr] :
                              odd_nb ? memory[aliased_addr] : memory[address_pipe[9]];
    wire [31:0] return_data = source_word ^
        ((corrupt && phase == 2 && address_pipe[9] == 9'd257) ? 32'h00010000 : 0);
    sdram_bist #(.ADDR_BITS(9), .WORDS(512), .RETENTION_CYCLES(50), .GAP_CYCLES(16),
        .IO_TIMEOUT_CYCLES(100), .INIT_TIMEOUT_CYCLES(200)) dut(
        .clk(clk), .rst(rst), .init_done(init_done), .refresh_active(refresh),
        .short_burst(short_burst), .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_en(rd_en), .rd_addr(rd_addr), .rd_valid(return_valid), .rd_data(return_data),
        .status(status), .phase(phase), .first_bad_addr(bad_addr),
        .first_expected(expected_data), .first_actual(actual_data), .done(done), .fault(fault),
        .head_map(head_map), .mismatch_count(bad_total),
        .mismatch_count_2(bad_total_2), .last_bad_addr(last_bad));
    integer i, writes, reads, returns, wr_seq, rd_seq, test_id;
    reg [1:0] old_phase;
    integer active_burst;
    reg was_active;
    reg [31:0] independent_pattern;
    // Data oracle is independent of the DUT function.
    function [31:0] oracle;
        input [1:0] p;
        input integer a;
        reg [31:0] word_value;
        begin
            word_value = (a << 11) | ((~a) & 2047);
            if (p==0) oracle=0;
            else if (p==1) oracle=32'hffffffff;
            else if (p==2) oracle=word_value ^ 32'h5a3c96e1;
            else oracle=~(word_value ^ 32'h5a3c96e1);
        end
    endfunction
    always @(posedge clk) begin
        if (rst) begin
            valid_pipe<=0;
            for (i=0;i<10;i=i+1) address_pipe[i]<=0;
            writes=0; reads=0; returns=0; wr_seq=0; rd_seq=0; old_phase=0;
            active_burst=0; was_active=0;
        end else begin
            valid_pipe <= {valid_pipe[8:0],rd_en};
            address_pipe[0]<=rd_addr;
            for(i=1;i<10;i=i+1) address_pipe[i]<=address_pipe[i-1];
            if (phase != old_phase) begin wr_seq=0; rd_seq=0; old_phase=phase; end
            if (wr_en && rd_en) $fatal(1,"simultaneous read/write");
            if (test_id==0 || test_id==1) begin
                if (wr_en || rd_en) active_burst=active_burst+1;
                else if(was_active) begin
                    if(active_burst != (short_burst ? 128 : 256))
                        $fatal(1,"wrong burst length %0d",active_burst);
                    active_burst=0;
                end
                was_active=wr_en || rd_en;
            end
            if ((wr_en || rd_en) && dut.in_burst==0) begin
                if (refresh) $fatal(1,"started during refresh");
                if ((wr_en ? wr_addr[1:0] : rd_addr[1:0]) != 0)
                    $fatal(1,"unaligned burst");
            end
            if (wr_en) begin
                if (wr_addr !== wr_seq[8:0] || wr_data !== oracle(phase,wr_seq))
                    $fatal(1,"write data/address mismatch phase=%0d addr=%0d",phase,wr_addr);
                memory[wr_addr]<=wr_data;
                writes=writes+1; wr_seq=wr_seq+1;
            end
            if (rd_en) begin
                if (rd_addr !== (rd_seq % 512)) $fatal(1,"read address mismatch");
                reads=reads+1; rd_seq=rd_seq+1;
            end
            if (return_valid) returns=returns+1;
        end
    end
    task reset_case;
        input integer mode;
        begin
            @(negedge clk); rst=1; init_done=0; refresh=0;
            short_burst=mode; corrupt=0; drop=0; extra=0; shift=0; odd_nb=0;
            repeat(4) @(negedge clk);
            rst=0; repeat(4) @(negedge clk);
        end
    endtask
    task wait_done;
        integer limit;
        begin
            limit=0;
            while(!done && limit<16000) begin @(negedge clk); limit=limit+1; end
            if (!done) $fatal(1,"BIST did not terminate test=%0d",test_id);
        end
    endtask
    task check_pass;
        begin
            wait_done;
            if(status!=4 || fault!=0 || writes!=2048 || reads!=4096 || returns!=4096)
                $fatal(1,"bad pass status=%h writes=%0d reads=%0d returns=%0d",status,writes,reads,returns);
            if (bad_total!=0 || bad_total_2!=0 || head_map!==32'hffffffff || last_bad!==0)
                $fatal(1,"clean run reported faults total=%0d/%0d map=%h last=%0d",
                       bad_total,bad_total_2,head_map,last_bad);
            repeat(20) @(negedge clk);
            if(wr_en || rd_en || status!=4) $fatal(1,"pass not sticky");
        end
    endtask
    initial begin
        test_id=0;
        reset_case(0);
        refresh=1; init_done=1;
        repeat(20) @(negedge clk);
        if(wr_en || rd_en) $fatal(1,"operation during initial refresh");
        refresh=0;
        // Raise refresh in a started burst: APUG011 ongoing bursts stay contiguous.
        wait(wr_en && dut.in_burst==7); @(negedge clk); refresh=1;
        repeat(10) begin @(negedge clk); if(!wr_en) $fatal(1,"cut an ongoing group"); end
        refresh=0;
        check_pass;
        test_id=1; reset_case(1); init_done=1; check_pass;
        test_id=2; reset_case(0); corrupt=1; init_done=1; wait_done;
        if(status!=4'he || fault!=1 || bad_addr!=257 ||
           expected_data!==oracle(2,257) || actual_data!==(oracle(2,257)^32'h00010000))
            $fatal(1,"corruption was not diagnosed exactly");
        // One faulty cell must read as one bad word in each of the two passes.
        if (bad_total!=1 || bad_total_2!=1 || head_map!==32'hffffffff || last_bad!==257)
            $fatal(1,"single-cell count wrong total=%0d/%0d map=%h last=%0d",
                   bad_total,bad_total_2,head_map,last_bad);
        repeat(12) @(negedge clk);
        if(status!=4'he || bad_addr!=257 || wr_en || rd_en) $fatal(1,"failure not sticky");
        test_id=3; reset_case(0); drop=1; init_done=1; wait_done;
        if(status!=4'hf || fault!=2) $fatal(1,"missing response not timed out");
        test_id=4; reset_case(0); wait_done;
        if(status!=4'hf || fault!=2) $fatal(1,"missing init not timed out");
        test_id=5; reset_case(0); extra=1; @(negedge clk); extra=0;
        if(!done || status!=4'hf || fault!=3) $fatal(1,"unsolicited response accepted");
        // Reset during an active read and then rerun a complete test.
        test_id=6; reset_case(1); init_done=1; wait(rd_en); reset_case(0);
        init_done=1; check_pass;
        // Read stream shifted by one word: every word is wrong, so the very
        // first bad word returns address 1's data. This is the C209 fingerprint.
        test_id=7; reset_case(0); shift=1; init_done=1; wait_done;
        if(status!=4'he || fault!=1 || bad_addr!=0 ||
           expected_data!==oracle(2,0) || actual_data!==oracle(2,1))
            $fatal(1,"shifted stream not reported at word 0");
        if(bad_total!=512 || bad_total_2!=512 || head_map!==32'd0 || last_bad!=511)
            $fatal(1,"shift not counted as all-bad total=%0d/%0d map=%h last=%0d",
                   bad_total,bad_total_2,head_map,last_bad);
        // Address bit 0 ignored: identical first-error triple, half the words.
        test_id=8; reset_case(0); odd_nb=1; init_done=1; wait_done;
        if(status!=4'he || fault!=1 || bad_addr!=0 ||
           expected_data!==oracle(2,0) || actual_data!==oracle(2,1))
            $fatal(1,"aliased read not reported at word 0");
        if(bad_total!=256 || bad_total_2!=256 || head_map!==32'haaaaaaaa || last_bad!=510)
            $fatal(1,"alias not counted as half-bad total=%0d/%0d map=%h last=%0d",
                   bad_total,bad_total_2,head_map,last_bad);
        $display("PASS: tb_sdram_bist bursts, patterns, replay, faults, reset, shift/alias split");
        $finish;
    end
    initial begin #5000000; $fatal(1,"global timeout"); end
endmodule
