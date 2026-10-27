`timescale 1ns/1ps
module tb_chinese_scroll;
    reg clk=0,rst=1,frame_start=0,de=1,run=1;
    reg [1:0] mode=0;
    reg [9:0] x=16,y=448;
    wire pixel;
    wire [23:0] color;
    reg [255:0] glyphs[0:130];
    reg [7:0] messages[0:1375];
    integer f,px,py,offset=0,frame_count=0,p,id,msg,checks=0;
    reg expected;
    always #5 clk=~clk;
    cpr_text_zh #(.UNCALIBRATED_PRESSURE(1)) dut(
        .clk(clk),.rst(rst),.frame_start(frame_start),.de(de),.x(x),.y(y),.mode(mode),
        .rate(2'd0),.depth(2'd0),.brightness(2'd0),.contrast(3'd0),.auto_running(run),
        .pause_warning(1'b0),.rotate_due(1'b0),.fault(1'b0),.beat(1'b0),.bpm_valid(1'b0),
        .page_status(12'd0),.count_bcd(16'd0),.interval_bcd(16'd0),.pause_bcd(16'd0),
        .rotate_bcd(24'd0),.bpm_bcd(12'd0),
        .subtitle_en(1'b1),   // 2026-10-27 新增端口：1 = 字幕带开（默认）
        .text_pixel(pixel),.text_color(color));
    task advance;
        begin
            @(negedge clk);frame_start=1;@(negedge clk);frame_start=0;
            if(mode!=1 || run)begin
                frame_count=frame_count+1;
                if(frame_count==3)begin frame_count=0;offset=(offset+1)%576;end
            end
        end
    endtask
    task check_window;
        begin
            msg=mode==0 ? 37 : mode==1 ? 38 : 39;
            // cpr_text_zh registers its character decode, so the mask for a
            // pixel is presented at the clock edge that ends that pixel. Drive
            // x one pixel behind the pixel under test and clock once per
            // column, which is what the real overlay counter does; the decode
            // is fed x+1, so x=px-1 makes the register hold the decode of px.
            for(py=447;py<465;py=py+1)for(px=14;px<626;px=px+1)begin
                x=px-1;y=py;@(posedge clk);#1;expected=0;
                p=(px-16+offset)%576;
                if(!rst && de && px>=16 && px<(mode==2 ? 368 : 624) && py>=448 && py<464 && p<512)begin
                    id=messages[msg*32+p/16];
                    expected=glyphs[id][255-(py-448)*16-p%16];
                end
                if(pixel!==expected)$fatal(1,"Chinese subtitle mismatch offset=%0d mode=%0d x=%0d y=%0d",offset,mode,px,py);
                checks=checks+1;
            end
        end
    endtask
    initial begin
        $readmemh("fixtures/chinese_glyphs.mem",glyphs);
        $readmemh("fixtures/chinese_messages.mem",messages);
        repeat(3)@(negedge clk);rst=0;check_window;
        for(f=0;f<9;f=f+1)begin advance;check_window;end
        mode=1;run=0;
        for(f=0;f<10;f=f+1)advance;
        check_window;
        run=1;for(f=0;f<6;f=f+1)advance;check_window;
        mode=2;check_window;
        // Exercise the four-cell gap and the exact last-offset wrap.
        for(f=0;f<1701;f=f+1)advance;
        check_window;
        for(f=0;f<12;f=f+1)begin advance;check_window;end
        de=0;check_window;de=1;
        rst=1;#1;check_window;
        @(negedge clk);rst=0;offset=0;frame_count=0;check_window;
        $display("PASS: tb_chinese_scroll checks=%0d",checks);$finish;
    end
    initial begin #60000000;$fatal(1,"TIMEOUT Chinese scrolling");end
endmodule
