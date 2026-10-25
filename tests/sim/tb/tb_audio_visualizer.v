`timescale 1ns/1ps
module tb_audio_visualizer;
reg clk=0,rst=1,enable=1,vs=1,de=0,sample_valid=0;
reg [23:0] rgb=0,left=0,right=0;
wire ov,od,wave_valid;
wire [23:0] out_rgb;
wire [5:0] level;
always #20 clk=~clk;
cpr_audio_visualizer dut(.clk(clk),.rst(rst),.enable(enable),.vs(vs),.de(de),.rgb(rgb),
    .sample_valid(sample_valid),.sample_left(left),.sample_right(right),
    .out_vs(ov),.out_de(od),.out_rgb(out_rgb),.level(level),.waveform_valid(wave_valid));
wire au,av,al;
wire [23:0] ad;
video_rgb_to_axis_640x480 axis(.I_clk(clk),.I_rst(rst),.I_vs(ov),.I_de(od),.I_rgb(out_rgb),
    .O_video_user(au),.O_video_valid(av),.O_video_last(al),.O_video_data(ad));
reg check_input=0,check_q=0,expected_vs_q=1,expected_de_q=0;
reg [23:0] expected_in=0,expected_q=0;
reg saved_check,saved_vs,saved_de;
reg [23:0] saved_expected;
integer checked=0,pixels=0,lines=0,column=0,sof=0;
always @(posedge clk) begin
    saved_check=check_q; saved_expected=expected_q;
    saved_vs=expected_vs_q; saved_de=expected_de_q;
    if (rst) begin check_q=0; expected_vs_q=1; expected_de_q=0; end
    else begin check_q=check_input; expected_q=expected_in; expected_vs_q=vs; expected_de_q=de; end
    #1;
    if (!rst && saved_check) begin
        if (out_rgb!==saved_expected || ov!==saved_vs || od!==saved_de)
            $fatal(1,"pixel/sideband mismatch got=%h expected=%h VS=%b/%b DE=%b/%b",out_rgb,saved_expected,ov,saved_vs,od,saved_de);
        checked=checked+1;
    end
    if (!rst && av) begin
        if (au) begin
            if (column!=0) $fatal(1,"SOF inside line");
            sof=sof+1;
        end
        if (al!==(column==639)) $fatal(1,"AXIS EOL is not pixel 640: col=%0d",column);
        pixels=pixels+1;
        if (al) begin lines=lines+1;column=0;end else column=column+1;
    end
end
function [23:0] background;
    input integer px,py;
    begin background={8'(px^py),8'(px),8'(py)};end
endfunction
function integer height;
    input integer index,pattern;
    integer q;
    begin
        if (pattern==2) height=5;
        else if (pattern==0 && index==0) height=0;
        else if (pattern==0 && index==1) height=10;
        else if (pattern==0 && (index==2 || index==3)) height=5;
        else if (pattern==0 && index==4) height=6;
        else begin
            q=((index/8)%2)==0 ? 3 : -4;
            if (pattern==1) q=((index/8)%2)==0 ? -4 : 3;
            height=5-q;
        end
    end
endfunction
function [23:0] expected_pixel;
    input integer px,py,pattern,vlevel,on;
    reg [23:0] c;
    reg [34:0] letter;
    integer tx,idx;
    begin
        c=background(px,py);
        if(on && py>=464) begin
            c=24'h081420;
            if(py==464 || py==479)c=24'h405060;
            if(px>=16 && px<528 && py==472)c=24'h203848;
            if(px>=16 && px<528 && py==467+height((px-16)/2,pattern))c=24'h50e0d0;
            if(px>=552 && px<616 && py>=467 && py<478)begin
                c=24'h203040;tx=px-552;
                if(vlevel!=0 && (tx<vlevel || vlevel==63) && tx%8!=7)
                    c=tx<40 ? 24'h20d060 : tx<56 ? 24'hffb020 : 24'hff4040;
            end
            if(py>=469 && py<476 && ((px>=536 && px<541)||(px>=542 && px<547)))begin
                letter=px<542 ? {5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01010,5'b00100} :
                                  {5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                idx=34-(py-469)*5-(px-(px<542 ? 536 : 542));
                if(letter[idx])c=24'hb6c9d5;
            end
        end
        expected_pixel=c;
    end
endfunction
task frame;
    begin
        @(negedge clk);check_input=0;de=0;vs=1;
        repeat(2)@(negedge clk);vs=0;
        repeat(2)@(negedge clk);vs=1;
        repeat(3)@(negedge clk);
    end
endtask
task pcm;
    input [23:0] l,r;
    begin
        @(negedge clk);sample_valid=1;left=l;right=r;
        @(negedge clk);sample_valid=0;left=24'h800000;right=24'h7fffff;
        repeat(2)@(negedge clk);
    end
endtask
task fill;
    input integer pattern;
    integer i,j;
    reg signed [23:0] sample;
    begin
        for(i=0;i<1024;i=i+1)begin
            j=i/4;
            sample=((j/8)%2)==0 ? 24'sd2000000 : -24'sd2000000;
            if(pattern==1)sample=-sample;
            if(pattern==2)sample=0;
            if(pattern==0)case(j)
                0:sample=24'h7fffff;1:sample=24'h800000;2:sample=0;
                3:sample=262144;4:sample=-262144;
            endcase
            pcm(sample,sample);
        end
        repeat(3)@(negedge clk);
    end
endtask
task raster;
    input integer pattern,vlevel,on;
    integer px,py,p0,l0,s0;
    begin
        p0=pixels;l0=lines;s0=sof;
        for(py=0;py<480;py=py+1)begin
            for(px=0;px<640;px=px+1)begin
                @(negedge clk);de=1;rgb=background(px,py);check_input=1;
                expected_in=expected_pixel(px,py,pattern,vlevel,on);
            end
            @(negedge clk);de=0;check_input=0;
            repeat(3)@(negedge clk);
        end
        repeat(6)@(negedge clk);
        if(pixels-p0!=307200 || lines-l0!=480 || sof-s0!=1)
            $fatal(1,"AXIS dimensions/SOF changed: pixels=%0d lines=%0d SOF=%0d",pixels-p0,lines-l0,sof-s0);
    end
endtask
integer i;
initial begin
    repeat(4)@(negedge clk);rst=0;
    fill(0);frame();
    if(!wave_valid || level!=63)$fatal(1,"full-scale publication/negative minimum failed");
    // Write the other bank without a frame boundary: display must stay A.
    fill(1);
    if(level!=63)$fatal(1,"VU changed inside frame");
    raster(0,63,1);
    frame();
    if(!wave_valid || level!=59)$fatal(1,"VU release or bank publication failed");
    raster(1,59,1);
    // Stopped valid: no stale trace; invalid full-scale bus noise is ignored.
    for(i=0;i<18;i=i+1)frame();
    if(level!=0 || wave_valid)$fatal(1,"stopped PCM did not clear scope/meter");
    fill(2);frame();
    if(!wave_valid || level!=0)$fatal(1,"digital silence produced a level");
    raster(2,0,1);
    // Runtime disable is an exact delayed pixel bypass, including the footer.
    @(negedge clk);enable=0;frame();raster(2,0,0);
    // Reset a partial capture: an old complete bank must not be republished.
    enable=1;for(i=0;i<20;i=i+1)pcm(24'h800000,0);
    @(negedge clk);rst=1;repeat(3)@(negedge clk);rst=0;frame();
    if(level!=0 || wave_valid)$fatal(1,"reset leaked stale audio state");
    // Stereo VU must see a full-scale right channel even with silent left.
    pcm(0,24'h800000);frame();
    if(level!=63)$fatal(1,"right-only full-scale peak was ignored");
    frame();if(level!=59)$fatal(1,"right-channel VU release failed");
    $display("PASS: tb_audio_visualizer checked=%0d pixels=%0d lines=%0d",checked,pixels,lines);$finish;
end
initial begin #80000000;$fatal(1,"audio visualizer timeout");end
endmodule
