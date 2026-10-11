`timescale 1ns/1ps
module tb_video_rgb_to_axis;
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1, vs=0, de=0;
    reg [23:0] rgb=0;
    wire user, valid, last;
    wire [23:0] data;
    integer frames=0, pixels=0, lines=0, sof_count=0, eol_count=0;
    integer f, y, x;
    video_rgb_to_axis_640x480 dut (
        .I_clk(clk), .I_rst(rst), .I_vs(vs), .I_de(de), .I_rgb(rgb),
        .O_video_user(user), .O_video_valid(valid), .O_video_last(last),
        .O_video_data(data));
    task drive;
        input active, expected_user, expected_last;
        input [23:0] pixel;
        begin
            @(negedge clk); de=active; rgb=pixel;
            @(posedge clk); #1;
            if (valid !== active || user !== expected_user || last !== expected_last)
                $fatal(1,"AXIS flags pixel=%0d active=%b user=%b last=%b expected=%b/%b",pixels,active,user,last,expected_user,expected_last);
            if (active && data !== pixel)
                $fatal(1,"AXIS data mismatch got=%h expected=%h",data,pixel);
            if (valid) pixels=pixels+1;
            if (user) sof_count=sof_count+1;
            if (last) eol_count=eol_count+1;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);
        rst=0;
        for (f=0; f<2; f=f+1) begin
            // VS edges occur in blanking, as in the reference raster.
            @(negedge clk); vs=1;
            drive(0,0,0,0);
            @(negedge clk); vs=0;
            drive(0,0,0,0);
            for (y=0; y<480; y=y+1) begin
                for (x=0; x<640; x=x+1)
                    drive(1,y==0 && x==0,x==639,{f[0],y[8:0],x[9:0],4'b1010});
                drive(0,0,0,0);
                drive(0,0,0,0);
                lines=lines+1;
            end
            frames=frames+1;
        end
        if (pixels!=614400 || sof_count!=2 || eol_count!=960 || lines!=960)
            $fatal(1,"AXIS coverage counts %0d/%0d/%0d/%0d",pixels,sof_count,eol_count,lines);
        @(negedge clk); rst=1;
        @(posedge clk); #1;
        if (valid || user || last || data!=0) $fatal(1,"AXIS reset did not flush");
        @(negedge clk); rst=0;
        drive(1,1,0,24'h123456);
        drive(0,0,0,0);
        $display("PASS: tb_video_rgb_to_axis frames=%0d pixels=%0d eol=%0d",frames,pixels,eol_count);
        $finish;
    end
    initial begin #20000000; $fatal(1,"TIMEOUT tb_video_rgb_to_axis"); end
endmodule
