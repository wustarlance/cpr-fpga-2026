`timescale 1ns/1ps
// Check the externally visible raster against fixed panel strings/old glyphs.
// No expected result reads DUT character, coordinate, counter or grade signals.
module tb_training_layout;
    reg clk=0, rst=1, vs=1, de=0;
    reg [1:0] mode=2, rate=2, depth=2;
    reg [31:0] count=87, rotate_ms=120000;
    reg [15:0] interval_ms=545, pause_ms=0;
    reg [7:0] bpm=110;
    reg bpm_valid=1, pause_warning=0, rotate_due=0, fault=0, beat=0;
    reg [23:0] base_rgb;
    wire [23:0] demo_rgb, adc_rgb;
    always #5 clk=~clk;
    cpr_overlay demo(.clk(clk),.rst(rst),.vs(vs),.de(de),.rgb(base_rgb),
        .mode(mode),.count(count),.rate(rate),.depth_grade(depth),
        .pause_warning(pause_warning),.rotate_due(rotate_due),.beat(beat),
        .interval_ms(interval_ms),.pause_ms(pause_ms),.rotate_remaining_ms(rotate_ms),
        .bpm(bpm),.bpm_valid(bpm_valid),.sensor_fault(fault),
        .brightness_level(2'd3),.contrast_level(3'd2),.auto_running(1'b1),.subtitle_en(1'b1),.out_rgb(demo_rgb));
    cpr_overlay #(.UNCALIBRATED_PRESSURE(1)) adc(.clk(clk),.rst(rst),.vs(vs),.de(de),.rgb(base_rgb),
        .mode(mode),.count(count),.rate(rate),.depth_grade(depth),
        .pause_warning(pause_warning),.rotate_due(rotate_due),.beat(beat),
        .interval_ms(interval_ms),.pause_ms(pause_ms),.rotate_remaining_ms(rotate_ms),
        .bpm(bpm),.bpm_valid(bpm_valid),.sensor_fault(fault),
        .brightness_level(2'd3),.contrast_level(3'd2),.auto_running(1'b1),.subtitle_en(1'b1),.out_rgb(adc_rgb));
    reg [7:0] panel_golden [0:839];
    reg [35:0] glyph_golden [0:255];
    reg [4095:0] panel_path, glyph_path, dump_prefix;
    integer px, py, which, state, col, row, gx, gy, address, checks=0;
    integer demo_dump=0, adc_dump=0, white=0, band=0;
    reg [23:0] expected, actual, color;
    reg [7:0] code;
    reg [34:0] bits;
    task frame;
        begin @(negedge clk);de=0;vs=1;@(negedge clk);vs=0;@(negedge clk);vs=1;end
    endtask
    task check_training;
        input integer warning_state;
        begin
            for(which=0;which<2;which=which+1)begin
                actual = which == 0 ? demo_rgb : adc_rgb;
                if(py>=16 && px>=384)begin
                    expected = px<388 ? 24'h405060 : 24'h101820;
                    if(px>=624 && px<632)begin
                        if(py>=96 && py<112)expected=warning_state ? 24'hffb020 : 24'h20d060;
                        if(py>=128 && py<144)expected=warning_state ? 24'hff4040 : 24'h20d060;
                        if(py>=352 && py<368)expected=warning_state ? 24'hff4040 : 24'h206040;
                        if(py>=384 && py<400)expected=warning_state ? 24'hffffff : 24'h304050;
                    end
                    if(px>=400 && px<624)begin
                        col=(px-400)/16; row=py/32;
                        gx=(px%16)/2; gy=(py%16)/2;
                        address=(warning_state*2+which)*210+row*14+col;
                        code=panel_golden[address]; bits=glyph_golden[code][34:0];
                        color=24'hffffff;
                        if(row==3)color=warning_state ? 24'hffb020 : 24'h20d060;
                        if(row==4)color=warning_state ? 24'hff4040 : 24'h20d060;
                        if((row==6 || row==9) && warning_state)color=24'hff4040;
                        if((row==7 || row==10) && warning_state)color=24'hffb020;
                        if(row==11)color=warning_state ? 24'hff4040 : 24'h206040;
                        if(py%32<16 && gx<5 && gy<7 && bits[34-gy*5-gx])expected=color;
                    end
                    if(actual!==expected)$fatal(1,"panel mismatch state=%0d adc=%0d x=%0d y=%0d expected=%h got=%h",warning_state,which,px,py,expected,actual);
                    checks=checks+1;
                end else if(py>=448 && py<464 && px>=16 && px<368)begin
                    if(actual!==24'hffffff && actual!==24'h182430)$fatal(1,"training subtitle band mismatch x=%0d y=%0d",px,py);
                    if(which==0)begin
                        if(actual==24'hffffff)white=white+1; else band=band+1;
                    end
                    checks=checks+1;
                end else if(py>=16)begin
                    if(actual!==base_rgb)$fatal(1,"tutorial image altered adc=%0d x=%0d y=%0d expected=%h got=%h",which,px,py,base_rgb,actual);
                    checks=checks+1;
                end
            end
        end
    endtask
    task raster;
        input integer selected_mode;
        input integer warning_state;
        input integer change_mid_frame;
        input integer total_lines;
        begin
            for(py=0;py<total_lines;py=py+1)begin
                for(px=0;px<640;px=px+1)begin
                    @(negedge clk);de=1;
                    // A changing RGB pattern detects replacement and pixel delay.
                    base_rgb={px[7:0],py[7:0],(px[7:0]^py[7:0])}; #1;
                    if(selected_mode==2)check_training(warning_state);
                    else if(py>=16 && !(py>=448 && py<464 && px>=16 && px<624))begin
                        if(demo_rgb!==base_rgb || adc_rgb!==base_rgb)$fatal(1,"teaching/auto image covered by stale training panel");
                        checks=checks+2;
                    end
                    if(selected_mode==2 && warning_state==0 && demo_dump!=0)begin
                        $fdisplay(demo_dump,"%06h",demo_rgb);$fdisplay(adc_dump,"%06h",adc_rgb);
                    end
                    if(change_mid_frame && py==240 && px==0)begin
                        // The current training frame must retain its old mode/data.
                        mode=0;count=32'hffffffff;interval_ms=16'hffff;
                        pause_ms=16'hffff;rotate_ms=32'hffffffff;
                        bpm=0;bpm_valid=0;rate=3;depth=3;
                        pause_warning=1;rotate_due=1;fault=1;beat=1;
                    end
                end
                @(negedge clk);de=0;#1;
                if(demo_rgb!==base_rgb || adc_rgb!==base_rgb)$fatal(1,"overlay changed blanking pixels");
                @(negedge clk);
            end
        end
    endtask
    initial begin
        base_rgb=24'h123456;
        if(!$value$plusargs("panel=%s",panel_path))panel_path="fixtures/training_panel_golden.mem";
        if(!$value$plusargs("glyph=%s",glyph_path))glyph_path="fixtures/glyph5x7_golden.mem";
        $readmemh(panel_path,panel_golden);$readmemh(glyph_path,glyph_golden);
        if(panel_golden[0]!==8'h20 || glyph_golden[32]!==0)$fatal(1,"missing raster fixtures");
        if($value$plusargs("dump_prefix=%s",dump_prefix))begin
            demo_dump=$fopen({dump_prefix,"-demo.rgb"},"w");adc_dump=$fopen({dump_prefix,"-adc.rgb"},"w");
            if(demo_dump==0 || adc_dump==0)$fatal(1,"cannot create raster dump");
        end
        repeat(3)@(negedge clk);rst=0;frame();
        raster(2,0,1,480);
        $display("Checked complete nominal raster for demo and ADC");
        if(white==0 || band==0)$fatal(1,"training subtitle missing");
        if(demo_dump!=0)begin $fclose(demo_dump);$fclose(adc_dump);demo_dump=0;adc_dump=0;end
        // Warning rows all end at y399. The nominal raster already checked
        // every subtitle/clipping pixel; do not repeat 80 unchanged rows.
        mode=2;frame();raster(2,1,0,400);
        $display("Checked warning rows for demo and ADC");
        // Teaching's complete image/subtitle raster is tested separately.
        // Here check both exits across y16, where the training panel begins.
        mode=0;frame();raster(0,1,0,18);
        mode=1;frame();raster(1,1,0,18);
        rst=1;#1;if(demo_rgb!==base_rgb || adc_rgb!==base_rgb)$fatal(1,"reset blanking mismatch");
        $display("PASS tb_training_layout %0d raster checks, demo/ADC, snapshots, warnings, mode return and blanking",checks);$finish;
    end
    initial begin #15000000;$fatal(1,"tb_training_layout TIMEOUT");end
endmodule
