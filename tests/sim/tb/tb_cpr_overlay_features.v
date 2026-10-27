`timescale 1ns/1ps
module tb_cpr_overlay_features;
    reg clk=0,rst=1,vs=1,de=0,auto_running=1;
    reg [1:0] mode=0;
    reg [2:0] contrast=2;
    wire [23:0] rgb;
    always #5 clk=~clk;
    cpr_overlay dut(.clk(clk),.rst(rst),.vs(vs),.de(de),.rgb(24'h123456),
        .mode(mode),.count(32'd87),.rate(2'd2),.depth_grade(2'd2),
        .pause_warning(1'b0),.rotate_due(1'b0),.beat(1'b0),
        .interval_ms(16'd545),.pause_ms(16'd0),.rotate_remaining_ms(32'd120000),
        .bpm(8'd110),.bpm_valid(1'b1),.sensor_fault(1'b0),
        .brightness_level(2'd3),.contrast_level(contrast),.auto_running(auto_running),.subtitle_en(1'b1),.out_rgb(rgb));
    integer x,y,white=0,bg=0,i,held_offset;
    task frame;
        begin @(negedge clk);de=0;vs=1;@(negedge clk);vs=0;@(negedge clk);vs=1;end
    endtask
    initial begin
        repeat(3)@(negedge clk);rst=0;frame();
        contrast=4;
        for(y=0;y<480;y=y+1)begin
            for(x=0;x<640;x=x+1)begin
                @(negedge clk);de=1;#1;
                if(y==200 && x==200 && rgb!==24'h123456)$fatal(1,"teaching image changed outside overlay");
                if(y>=448 && y<464 && x>=16 && x<624)begin
                    if(rgb==24'hffffff)white=white+1;
                    else if(rgb==24'h182430)bg=bg+1;
                    else $fatal(1,"subtitle escaped its two-color band");
                end
                if(y==470 && x==200 && rgb!==24'h123456)$fatal(1,"subtitle clipping failed below band");
            end
            @(negedge clk);de=0;@(negedge clk);
        end
        if(white==0 || bg==0)$fatal(1,"subtitle text/background missing");
        if(dut.frame_contrast!==2)$fatal(1,"contrast header changed mid-frame");
        frame();if(dut.frame_contrast!==4)$fatal(1,"contrast header did not capture next frame");
        mode=1;auto_running=0;frame();held_offset=dut.u_subtitles.offset;
        for(i=0;i<12;i=i+1)frame();
        if(dut.u_subtitles.offset!=held_offset)$fatal(1,"auto pause did not pause subtitles");
        auto_running=1;frame();for(i=0;i<6;i=i+1)frame();
        if(dut.u_subtitles.offset==held_offset)$fatal(1,"auto resume did not resume subtitles");
        rst=1;#1;
        if(dut.u_subtitles.offset!==0)$fatal(1,"subtitle reset");
        $display("PASS tb_cpr_overlay_features white=%0d background=%0d",white,bg);$finish;
    end
    initial begin #5000000;$fatal(1,"tb_cpr_overlay_features TIMEOUT");end
endmodule
