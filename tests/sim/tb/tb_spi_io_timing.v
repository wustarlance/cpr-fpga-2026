`timescale 1ns/1ps
// Product SPI master with a delayed card output, not a show-ahead SPI stub.
module tb_spi_io_timing;
    reg clk=0, rst=1, ncs=1, request=0;
    reg [15:0] divider=0;
    reg [7:0] tx=0;
    wire sck, mosi, ack, ncs_out;
    reg miso=1;
    wire [7:0] rx;
    integer sample_count=0, edge_count=0, card_bit=7;
    integer delay_ns=14, half_ns=20, late_control=0;
    reg [7:0] card_data=8'h96;
    realtime last_fall=0, last_rise=0, last_mosi=0;
    reg checking=0;
    always #5 clk=~clk;
    spi_master dut(.sys_clk(clk),.rst(rst),.nCS(ncs_out),.DCLK(sck),
        .MOSI(mosi),.MISO(miso),.CPOL(1'b1),.CPHA(1'b1),.nCS_ctrl(ncs),
        .clk_div(divider),.wr_req(request),.wr_ack(ack),.data_in(tx),.data_out(rx));

    // The card launches on falling SCK. This delay includes the selected
    // test card's output delay only; FPGA/PCB delays are budgeted separately.
    always @(negedge sck) if (checking && !ncs_out) begin
        last_fall=$realtime;
        edge_count=edge_count+1;
        miso <= #(delay_ns) card_data[card_bit];
        card_bit=card_bit-1;
    end
    always @(posedge sck) if (checking && !ncs_out) begin
        if ($realtime-last_fall != half_ns) $fatal(1,"SPI half period mismatch");
        if ($realtime-last_mosi < 5) $fatal(1,"MOSI setup below 5 ns");
        if (mosi !== tx[7-sample_count]) $fatal(1,"MOSI bit order mismatch");
        last_rise=$realtime;
        sample_count=sample_count+1;
    end
    always @(mosi) begin
        if(checking && !ncs_out && sample_count>0 && $realtime-last_rise<5)
            $fatal(1,"MOSI hold below 5 ns");
        last_mosi=$realtime;
    end
    task transfer;
        input integer div_value;
        input integer card_delay;
        input [7:0] sent, response;
        begin
            @(negedge clk);
            divider=div_value; half_ns=(div_value+2)*10;
            delay_ns=card_delay; tx=sent; card_data=response;
            card_bit=7; sample_count=0; edge_count=0;
            ncs=0; checking=1; request=1;
            wait(ack);
            #1;
            if(rx !== response) $fatal(1,"MISO mismatch div=%0d delay=%0d received=%h expected=%h",divider,delay_ns,rx,response);
            if(sample_count!=8 || edge_count!=8) $fatal(1,"Missing SPI edge");
            @(negedge clk);request=0;
            repeat(5) @(negedge clk);
            checking=0;ncs=1;
        end
    endtask
    initial begin
        late_control=$test$plusargs("LATE_MISO");
        repeat(4) @(negedge clk);rst=0;
        repeat(4) @(negedge clk);
        transfer(248,50,8'ha5,8'h96); // 200 kHz, 2500 ns half period.
        transfer(0,late_control?30:14,8'h69,8'h96); // 25 MHz, 20 ns half.
        transfer(0,14,8'hc3,8'h5a);
        transfer(1,21,8'h3c,8'ha6); // Safer product phase, 30 ns half.
        $display("PASS: tb_spi_io_timing init_half=2500ns legacy_half=20ns product_half=30ns");
        $finish;
    end
    initial begin #200000; $fatal(1,"SPI timing timeout");end
endmodule
