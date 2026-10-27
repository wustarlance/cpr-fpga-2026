`timescale 1ns/1ps
// Integrate actual fade, Chinese OSD, audio footer and AXIS with a tutorial BMP.
// Reference OSD is unchanged product RTL fed an independently fixed gain (0/16).
// This checks placement/latency of NEW stages, not the font implementation.
module tb_presentation_pipeline;
reg clk=0,rst=1,vs=1,de=0,request=0,pcm_valid=0;
reg [23:0] rgb=0,pcm=0;
reg [1:0] mode=0;
wire fv,fd,ov,od;
wire [23:0] frgb,osd_rgb,out_rgb;
wire [4:0] gain;
wire [5:0] level;
wire waveform_valid;
always #20 clk=~clk;
cpr_slide_fade f(.clk(clk),.rst(rst),.request_async(request),.vs(vs),.de(de),.rgb(rgb),
    .ready(),.out_vs(fv),.out_de(fd),.out_rgb(frgb),.gain(gain));
`define STATUS_PORTS .mode(mode),.count(32'd87),.rate(2'd2),.depth_grade(2'd2), \
 .pause_warning(1'b0),.rotate_due(1'b0),.beat(1'b0),.interval_ms(16'd545),.pause_ms(16'd0), \
 .rotate_remaining_ms(32'd120000),.bpm(8'd110),.bpm_valid(1'b1),.sensor_fault(1'b0), \
 .brightness_level(2'd3),.contrast_level(3'd2),.auto_running(1'b1),.page_status(12'hb11), \
 .subtitle_en(1'b1)
cpr_overlay #(.CHINESE_UI(1),.PAGE_STATUS_ENABLE(1)) osd(
    .clk(clk),.rst(rst),.vs(fv),.de(fd),.rgb(frgb),`STATUS_PORTS,.out_rgb(osd_rgb));
cpr_audio_visualizer scope(.clk(clk),.rst(rst),.enable(1'b1),.vs(fv),.de(fd),.rgb(osd_rgb),
    .sample_valid(pcm_valid),.sample_left(pcm),.sample_right(pcm),
    .out_vs(ov),.out_de(od),.out_rgb(out_rgb),.level(level),.waveform_valid(waveform_valid));
reg rv0=1,rv1=1,rd0=0,rd1=0;
reg [23:0] rr0=0,rr1=0;
integer phase=0;
always @(posedge clk)begin
    if(rst)begin rv0<=1;rv1<=1;rd0<=0;rd1<=0;rr0<=0;rr1<=0;end
    else begin
        rv0<=vs;rv1<=rv0;rd0<=de;rd1<=rd0;
        rr0<=phase==2 ? 24'd0 : rgb;rr1<=rr0;
    end
end
wire [23:0] reference_rgb;
cpr_overlay #(.CHINESE_UI(1),.PAGE_STATUS_ENABLE(1)) reference(
    .clk(clk),.rst(rst),.vs(rv1),.de(rd1),.rgb(rr1),`STATUS_PORTS,.out_rgb(reference_rgb));
`undef STATUS_PORTS
reg [23:0] expected0,expected1;
reg ed0=0,ed1=0,ev0=1,ev1=1;
reg [9:0] ey0=0,ey1=0;
integer checks=0,output_pixels=0,dump_fd=0;
reg [4095:0] dump_prefix;
always @(posedge clk)begin
    if(rst)begin ed0<=0;ed1<=0;ev0<=1;ev1<=1;end
    else begin
        expected0<=reference_rgb;expected1<=expected0;
        ed0<=rd1;ed1<=ed0;ev0<=rv1;ev1<=ev0;
        ey0<=reference.y;ey1<=ey0;
    end
    #1;
    if(!rst)begin
        if(od!==ed1 || ov!==ev1)$fatal(1,"presentation VS/DE was not delayed with RGB");
        if(od)begin
            output_pixels=output_pixels+1;
            if(ey1<464)begin
                if(out_rgb!==expected1)$fatal(1,"picture/OSD mismatch phase=%0d y=%0d got=%h expected=%h",phase,ey1,out_rgb,expected1);
                checks=checks+1;
            end
            if(dump_fd)$fwrite(dump_fd,"%06x\n",out_rgb);
        end
    end
end
wire au,av,al;
wire [23:0] ad;
video_rgb_to_axis_640x480 axis(.I_clk(clk),.I_rst(rst),.I_vs(ov),.I_de(od),.I_rgb(out_rgb),
    .O_video_user(au),.O_video_valid(av),.O_video_last(al),.O_video_data(ad));
integer pixels=0,lines=0,col=0,sof=0;
always @(posedge clk)begin
    #2;
    if(rst)begin pixels=0;lines=0;col=0;sof=0;end
    else if(av)begin
        if(al!==(col==639))$fatal(1,"presentation EOL moved");
        if(au)begin if(pixels!=0)$fatal(1,"extra SOF");sof=sof+1;end
        pixels=pixels+1;
        if(al)begin col=0;lines=lines+1;end else col=col+1;
    end
end
reg [7:0] bmp[0:921653];
integer file,n,i,px,py,offset,start_pixels;
task frame;
    begin
        @(negedge clk);de=0;vs=1;repeat(3)@(negedge clk);vs=0;
        repeat(3)@(negedge clk);vs=1;repeat(6)@(negedge clk);
    end
endtask
initial begin
    file=$fopen("../../project/assets/tutorials/bmp_training_safe/02_compressions.bmp","rb");
    if(!file)$fatal(1,"missing tutorial BMP");
    n=$fread(bmp,file);$fclose(file);if(n!=921654)$fatal(1,"bad tutorial size");
    n=$value$plusargs("dump=%s",dump_prefix);
    for(phase=0;phase<3;phase=phase+1)begin
        @(negedge clk);rst=1;de=0;vs=1;request=0;pcm_valid=0;
        mode=phase==0 ? 0 : 2;
        repeat(5)@(negedge clk);rst=0;
        if(phase==2)begin request=1;repeat(5)@(negedge clk);repeat(16)frame();end
        for(i=0;i<1024;i=i+1)begin
            @(negedge clk);pcm_valid=1;pcm=(i/55)%2 ? -24'sd2000000 : 24'sd2000000;
            @(negedge clk);pcm_valid=0;repeat(2)@(negedge clk);
        end
        repeat(3)@(negedge clk);frame();
        if(gain!=(phase==2 ? 0 : 16) || !waveform_valid || level!=15)$fatal(1,"presentation setup");
        if(n)begin
            case(phase)
                0:dump_fd=$fopen({dump_prefix,"-teaching.rgb"},"w");
                1:dump_fd=$fopen({dump_prefix,"-training.rgb"},"w");
                2:dump_fd=$fopen({dump_prefix,"-black.rgb"},"w");
            endcase
            if(!dump_fd)$fatal(1,"cannot create raster dump");
        end
        start_pixels=output_pixels;
        for(py=0;py<480;py=py+1)begin
            for(px=0;px<640;px=px+1)begin
                @(negedge clk);de=1;offset=54+(479-py)*1920+px*3;
                rgb={bmp[offset+2],bmp[offset+1],bmp[offset]};
            end
            @(negedge clk);de=0;repeat(3)@(negedge clk);
        end
        repeat(10)@(negedge clk);
        if(pixels!=307200 || lines!=480 || sof!=1 || output_pixels-start_pixels!=307200)
            $fatal(1,"presentation frame dimensions changed");
        if(dump_fd)begin $fclose(dump_fd);dump_fd=0;end
        $display("CHECK presentation phase=%0d pixels=%0d lines=%0d",phase,pixels,lines);
    end
    $display("PASS: tb_presentation_pipeline checks=%0d three full tutorial/OSD/footer frames",checks);$finish;
end
initial begin #60000000;$fatal(1,"presentation pipeline timeout");end
endmodule
