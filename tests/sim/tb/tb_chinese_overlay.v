`timescale 1ns/1ps
module tb_chinese_overlay;
    reg clk=0,rst=1,vs=1,de=0;
    reg [1:0] mode=2,rate=2,depth=2,brightness=3;
    reg [2:0] contrast=2;
    reg [31:0] count=87,rotate_ms=120000;
    reg [15:0] interval_ms=545,pause_ms=0;
    reg [7:0] bpm=110;
    reg valid=1,pause_warning=0,rotate_due=0,fault=0,beat=0,auto_running=0,subtitle_en=1;
    reg [11:0] page=12'hb11;
    reg [23:0] base_rgb;
    wire [23:0] demo_rgb,adc_rgb;
    always #5 clk=~clk;
    cpr_overlay #(.CHINESE_UI(1),.PAGE_STATUS_ENABLE(1)) demo(
        .clk(clk),.rst(rst),.vs(vs),.de(de),.rgb(base_rgb),.mode(mode),.count(count),.rate(rate),.depth_grade(depth),
        .pause_warning(pause_warning),.rotate_due(rotate_due),.beat(beat),.interval_ms(interval_ms),.pause_ms(pause_ms),
        .rotate_remaining_ms(rotate_ms),.bpm(bpm),.bpm_valid(valid),.sensor_fault(fault),.brightness_level(brightness),
        .contrast_level(contrast),.auto_running(auto_running),.page_status(page),.subtitle_en(subtitle_en),.out_rgb(demo_rgb));
    cpr_overlay #(.CHINESE_UI(1),.PAGE_STATUS_ENABLE(1),.UNCALIBRATED_PRESSURE(1)) adc(
        .clk(clk),.rst(rst),.vs(vs),.de(de),.rgb(base_rgb),.mode(mode),.count(count),.rate(rate),.depth_grade(depth),
        .pause_warning(pause_warning),.rotate_due(rotate_due),.beat(beat),.interval_ms(interval_ms),.pause_ms(pause_ms),
        .rotate_remaining_ms(rotate_ms),.bpm(bpm),.bpm_valid(valid),.sensor_fault(fault),.brightness_level(brightness),
        .contrast_level(contrast),.auto_running(auto_running),.page_status(page),.subtitle_en(subtitle_en),.out_rgb(adc_rgb));
    reg [255:0] glyphs[0:133];
    reg [31:0] cells[0:9599];
    reg [7:0] bmp_bytes[0:921653];
    integer fd,n,px,py,s,a,address,offset,checks=0,white=0,dump_demo=0,dump_adc=0;
    reg [31:0] cell_value;
    reg [7:0] glyph_id;
    reg [23:0] expected,actual;
    reg [4095:0] dump_prefix;
    task frame;
        begin @(negedge clk);de=0;vs=1;@(negedge clk);vs=0;@(negedge clk);vs=1;end
    endtask
    task set_state;
        input integer state;
        begin
            @(negedge clk);de=0;vs=1;rst=1;repeat(3)@(negedge clk);rst=0;
            mode=state<2 ? 2 : state==2 ? 0 : 1;
            rate=state==1 ? 1 : 2;depth=state==1 ? 3 : 2;
            count=state==1 ? 32'hffffffff : 87;rotate_ms=state==1 ? 32'hffffffff : 120000;
            interval_ms=state==1 ? 65535 : 545;pause_ms=state==1 ? 65535 : 0;
            bpm=state==1 ? 255 : 110;valid=state!=1;
            pause_warning=state==1;rotate_due=state==1;fault=state==1;beat=state==1;
            brightness=state==1 ? 0 : 3;contrast=state==1 ? 4 : 2;
            page=state==0 ? 12'hb11 : state==1 ? 12'hb1b : state==2 ? 12'hb15 : 12'hb19;
            frame;
        end
    endtask
    initial begin
        $readmemh("fixtures/chinese_glyphs.mem",glyphs);
        $readmemh("fixtures/chinese_screen_cells.mem",cells);
        fd=$fopen("../../project/assets/tutorials/bmp_training_safe/02_compressions.bmp","rb");
        if(fd==0)$fatal(1,"missing tutorial BMP");
        n=$fread(bmp_bytes,fd);$fclose(fd);
        if(n!=921654 || bmp_bytes[0]!=8'h42 || bmp_bytes[1]!=8'h4d)$fatal(1,"bad tutorial fixture");
        if($value$plusargs("dump=%s",dump_prefix))begin
            dump_demo=$fopen({dump_prefix,"-demo.rgb"},"w");dump_adc=$fopen({dump_prefix,"-adc.rgb"},"w");
            if(!dump_demo || !dump_adc)$fatal(1,"cannot create raster dumps");
        end
        for(s=0;s<4;s=s+1)begin
            set_state(s);
            for(py=0;py<480;py=py+1)begin
                for(px=0;px<640;px=px+1)begin
                    @(negedge clk);de=1;
                    offset=54+(479-py)*1920+px*3;
                    base_rgb={bmp_bytes[offset+2],bmp_bytes[offset+1],bmp_bytes[offset]};#1;
                    for(a=0;a<2;a=a+1)begin
                        expected=base_rgb;
                        if(s<2 && px>=384 && py>=16)expected=px<388 ? 24'h405060 : 24'h101820;
                        if(py<16)expected=s<2 ? 24'h805020 : s==2 ? 24'h204080 : 24'h206040;
                        if(s<2 && px>=624 && px<632)begin
                            if(py>=96 && py<112)expected=s==1 ? 24'hffb020 : 24'h20d060;
                            if(py>=128 && py<144)expected=s==1 ? 24'hff4040 : 24'h20d060;
                            if(py>=352 && py<368)expected=s==1 ? 24'hff4040 : 24'h206040;
                            if(py>=384 && py<400)expected=s==1 ? 24'hffffff : 24'h304050;
                        end
                        if(subtitle_en && py>=448 && py<464 && px>=16 && px<(s<2 ? 368 : 624))expected=24'h182430;
                        address=(s*2+a)*1200+(py/16)*40+px/16;
                        cell_value=cells[address];glyph_id=cell_value[7:0];
                        if(glyph_id>=134)$fatal(1,"reference glyph out of range");
                        if(glyphs[glyph_id][255-(py%16)*16-(px%16)])begin expected=cell_value[31:8];white=white+1;end
                        actual=a==0 ? demo_rgb : adc_rgb;
                        if(actual!==expected)$fatal(1,"Chinese raster mismatch state=%0d adc=%0d x=%0d y=%0d expected=%h got=%h",s,a,px,py,expected,actual);
                        checks=checks+1;
                    end
                    if(s==0 && dump_demo)begin $fwrite(dump_demo,"%06x\n",demo_rgb);$fwrite(dump_adc,"%06x\n",adc_rgb);end
                    // Every status changes mid-frame. Its old snapshot must
                    // remain visible through the last active pixel.
                    if(py==200 && px==300)begin mode=1;rate=3;depth=0;count=456;pause_warning=!pause_warning;
                        rotate_due=!rotate_due;fault=!fault;beat=0;brightness=1;contrast=1;page=0;end
                end
                @(negedge clk);de=0;base_rgb=24'h123456;#1;
                if(demo_rgb!==base_rgb || adc_rgb!==base_rgb)$fatal(1,"blanking RGB was changed or delayed");
                @(negedge clk);
            end
        end
        if(white<1000)$fatal(1,"Chinese checker exercised no useful text");
        if(dump_demo)begin $fclose(dump_demo);$fclose(dump_adc);end
        $display("PASS: tb_chinese_overlay checks=%0d",checks);$finish;
    end
    initial begin #20000000;$fatal(1,"TIMEOUT Chinese raster");end
endmodule
