`timescale 1ns/1ps
// Check the visible grade row for all four grades and both input/UI variants.
module tb_depth_labels;
    reg clk=0,rst=1,vs=1,de=0;
    reg [1:0] depth=0;
    reg [23:0] base_rgb=24'h123456;
    wire [23:0] result[0:3];
    always #5 clk=~clk;
    genvar n;
    generate for(n=0;n<4;n=n+1)begin: views
        cpr_overlay #(.CHINESE_UI(n>=2),.UNCALIBRATED_PRESSURE(n%2)) dut(
            .clk(clk),.rst(rst),.vs(vs),.de(de),.rgb(base_rgb),.mode(2'd2),
            .count(32'd0),.rate(2'd0),.pause_warning(1'b0),.rotate_due(1'b0),.beat(1'b0),
            .depth_grade(depth),.interval_ms(16'd0),.pause_ms(16'd0),.rotate_remaining_ms(32'd120000),
            .bpm(8'd0),.bpm_valid(1'b0),.sensor_fault(1'b0),.brightness_level(2'd3),
            .contrast_level(3'd4),.auto_running(1'b0),.page_status(12'd0),.subtitle_en(1'b1),
            .out_rgb(result[n]));
    end endgenerate
    reg [7:0] ascii_rows[0:111],zh_rows[0:111];
    reg [35:0] ascii_glyphs[0:255];
    reg [255:0] zh_glyphs[0:133];
    integer grade,px,py,view,col,gx,gy,addr,code,checks=0,pixels=0,fd=0;
    reg on;
    reg [23:0] expected,color;
    reg [4095:0] dump_path;
    task frame;
        begin @(negedge clk);de=0;vs=1;@(negedge clk);vs=0;@(negedge clk);vs=1;end
    endtask
    initial begin
        $readmemh("fixtures/depth_labels_ascii.mem",ascii_rows);
        $readmemh("fixtures/depth_labels_zh.mem",zh_rows);
        $readmemh("fixtures/glyph5x7_golden.mem",ascii_glyphs);
        $readmemh("fixtures/chinese_glyphs.mem",zh_glyphs);
        if($value$plusargs("dump=%s",dump_path))begin
            fd=$fopen(dump_path,"w");
            if(!fd)$fatal(1,"cannot open grade raster output");
        end
        repeat(3)@(negedge clk);rst=0;
        for(grade=0;grade<4;grade=grade+1)begin
            depth=grade;frame;
            color=grade==0 ? 24'h607080 : grade==1 ? 24'hffb020 : grade==2 ? 24'h20d060 : 24'hff4040;
            for(py=0;py<144;py=py+1)begin
                for(px=0;px<640;px=px+1)begin
                    @(negedge clk);de=1;#1;
                    if(py>=128 && px>=400 && px<624)begin
                        col=(px-400)/16;
                        for(view=0;view<4;view=view+1)begin
                            addr=(grade*2+view%2)*14+col;
                            expected=24'h101820;
                            if(view<2)begin
                                code=ascii_rows[addr];gx=(px%16)/2;gy=(py%16)/2;
                                on=gx<5 && gy<7 && ascii_glyphs[code][34-gy*5-gx];
                            end else begin
                                code=zh_rows[addr];
                                on=zh_glyphs[code][255-(py%16)*16-(px%16)];
                            end
                            if(on)begin expected=color;pixels=pixels+1;end
                            if(result[view]!==expected)
                                $fatal(1,"grade label mismatch grade=%0d ui=%0d adc=%0d x=%0d y=%0d expected=%h got=%h",grade,view/2,view%2,px,py,expected,result[view]);
                            if(fd)$fdisplay(fd,"%06x",result[view]);
                            checks=checks+1;
                        end
                    end
                end
                @(negedge clk);de=0;
                @(negedge clk);
            end
        end
        if(pixels<1000)$fatal(1,"grade labels did not draw enough pixels");
        if(fd)$fclose(fd);
        $display("PASS: tb_depth_labels checks=%0d",checks);$finish;
    end
    initial begin #10000000;$fatal(1,"TIMEOUT depth labels");end
endmodule
