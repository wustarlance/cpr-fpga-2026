`timescale 1ns/1ps
// Independent mathematical scoreboard: compare every accepted destination
// pixel against contain geometry and source-coordinate integer division.
module tb_bmp_scaled #(parameter DW=16, DH=12, FULL=0);
    reg clk=0,rst=1,scan_start=0,load_start=0,ack=0,pixel_ready=0;
    always #5 clk=~clk;
    wire ready,scan_done,found,request,push,sd_read,error;
    wire [31:0] sd_addr,found_sector;
    wire [2:0] total;
    wire [23:0] pixel;
    reg [7:0] sd_data=0;
    reg sd_valid=0,sd_end=0;
    integer w,h,offset,stride,length,fw,fh,left,bottom,count=0,cycle=0;
    integer requests=0,profile=0,seen=0;
    reg [31:0] last_scan=4;
    bmp_read_scaled #(.DST_WIDTH(DW),.DST_HEIGHT(DH)) dut(
        .clk(clk),.rst(rst),.cancel(1'b0),.sd_sec_ready(!rst),.sd_sec_read_error(1'b0),
        .abort_sd(),.operation_error(),.error_code(),.ready(ready),.scan_start(scan_start),
        .scan_start_sector(32'd4),.scan_max_sector(last_scan),.scan_target_count(3'd4),
        .scan_done(scan_done),.scan_found_valid(found),.scan_found_sector(found_sector),
        .scan_found_total(total),.load_start(load_start),.load_sector(32'd4),
        .sd_init_done(!rst),.state_code(),.bmp_width(DW[15:0]),.bmp_height(DH[15:0]),
        .write_req(request),.write_req_ack(ack),.sd_sec_read(sd_read),.sd_sec_read_addr(sd_addr),
        .sd_sec_read_data(sd_data),.sd_sec_read_data_valid(sd_valid),.sd_sec_read_end(sd_end),
        .bmp_data_wr_en(push),.bmp_data(pixel),.pixel_ready(pixel_ready),.load_error(error));

    function [23:0] source_pixel;
        input integer x,y;
        reg [7:0] r,g,b;
        begin r=x*17+y*9;g=x*3+y*21;b=x*13+y*5;source_pixel={r,g,b};end
    endfunction
    function [7:0] file_byte;
        input integer pos;
        integer n,x,y,c;
        reg [23:0] p;
        begin
            file_byte=0;
            case(pos)
                0:file_byte="B";1:file_byte="M";
                2:file_byte=length;3:file_byte=length>>8;4:file_byte=length>>16;5:file_byte=length>>24;
                10:file_byte=offset;11:file_byte=offset>>8;12:file_byte=offset>>16;13:file_byte=offset>>24;
                14:file_byte=40;
                18:file_byte=w;19:file_byte=w>>8;20:file_byte=w>>16;21:file_byte=w>>24;
                22:file_byte=h;23:file_byte=h>>8;24:file_byte=h>>16;25:file_byte=h>>24;
                26:file_byte=1;28:file_byte=(profile==1)?16:24;30:file_byte=(profile==2)?1:0;
                default:begin
                    if(pos>=offset && pos<length)begin
                        n=pos-offset;y=n/stride;x=(n%stride)/3;c=(n%stride)%3;
                        p=source_pixel(x,y);
                        file_byte=(n%stride>=w*3)?8'hee:(p>>(8*c));
                    end
                end
            endcase
        end
    endfunction

    // Full sectors cannot be stalled. Deliberate gaps include BGR and row
    // boundaries; the scaler must preserve both across sector boundaries.
    integer i,base;
    initial forever begin
        wait(sd_read && !rst);
        base=(sd_addr-4)*512;requests=requests+1;
        for(i=0;i<512;i=i+1)begin
            @(negedge clk);sd_valid=1;sd_data=file_byte(base+i);
            if(i%71==17)begin @(negedge clk);sd_valid=0;end
        end
        @(negedge clk);sd_valid=0;
        repeat(3)@(negedge clk);
        sd_end=1;@(negedge clk);sd_end=0;
        wait(!sd_read);
    end
    // Delayed frame-write ACK followed by a held clear phase.
    initial forever begin
        wait(request);repeat(7)@(negedge clk);ack=1;
        wait(!request);repeat(8)@(negedge clk);ack=0;
    end
    integer x,y,sx,sy;
    reg [23:0] expected;
    always @(negedge clk) begin
        cycle=cycle+1;
        pixel_ready=(cycle%19<9)&&(cycle%257<190);
    end
    always @(posedge clk) if(!rst)begin
        if(found)seen=seen+1;
        if(push)begin
            if(ack)$fatal(1,"pixel emitted during FIFO clear");
            if(count>=DW*DH)$fatal(1,"too many output pixels");
            x=count%DW;y=count/DW;expected=24'h102030;
            if(x>=left && x<left+fw && y>=bottom && y<bottom+fh)begin
                sx=(x-left)*w/fw;sy=(y-bottom)*h/fh;
                expected=source_pixel(sx,sy);
            end
            if(pixel!==expected)$fatal(1,"pixel %0d %dx%d actual=%h expected=%h",count,w,h,pixel,expected);
            count=count+1;
        end
    end
    task run_image;
        input integer iw,ih,io;
        integer timeout;
        begin
            w=iw;h=ih;offset=io;stride=(w*3+3)&~3;length=offset+stride*h;
            if(w*DH>=h*DW)begin fw=DW;fh=(h*DW+w/2)/w;if(fh<1)fh=1;end
            else begin fh=DH;fw=(w*DH+h/2)/h;if(fw<1)fw=1;end
            left=(DW-fw)/2;bottom=(DH-fh+1)/2;count=0;
            @(negedge clk);load_start=1;@(negedge clk);load_start=0;
            timeout=0;
            while(!ready)begin
                @(negedge clk);timeout=timeout+1;
                if(timeout>10000000)$fatal(1,"image timeout %dx%d state=%d",w,h,dut.state);
            end
            if(error || count!=DW*DH)$fatal(1,"image incomplete %dx%d count=%d",w,h,count);
            repeat(10)@(negedge clk);
        end
    endtask
    initial begin
        w=16;h=12;offset=54;stride=48;length=630;
        repeat(5)@(negedge clk);rst=0;
        if(FULL)begin
            run_image(DW,DH,54);
            run_image(426,240,54);
            $display("PASS tb_bmp_scaled_frame: full raster identity and arbitrary BMP width");$finish;
        end
        run_image(16,12,54); // exact passthrough
        run_image(8,6,54);   // enlargement
        run_image(32,24,54); // reduction
        run_image(21,14,54); // non-integer ratio, one byte padding
        run_image(6,9,54);   // portrait, two byte padding
        run_image(7,3,600);  // three byte padding, pixel offset in later sector
        run_image(1,25,54);  // extremely narrow, minimum content width
        run_image(50,1,54);  // minimum content height and asymmetric black bars
        // Malformed or unsupported headers must return idle without opening
        // another memory transaction or publishing a partial destination frame.
        profile=1;
        @(negedge clk);load_start=1;@(negedge clk);load_start=0;
        wait(ready);if(!error)$fatal(1,"unsupported bit depth accepted");
        profile=2;
        @(negedge clk);load_start=1;@(negedge clk);load_start=0;
        wait(ready);if(!error)$fatal(1,"compressed BMP accepted");
        profile=0;h=-1;
        @(negedge clk);load_start=1;@(negedge clk);load_start=0;
        wait(ready);if(!error)$fatal(1,"top-down BMP accepted by bottom-up path");
        h=1;w=2049;stride=(w*3+3)&~3;length=offset+stride;
        @(negedge clk);load_start=1;@(negedge clk);load_start=0;
        wait(ready);if(!error)$fatal(1,"oversize BMP accepted");
        w=7;h=3;stride=24;length=offset+stride; // claims only one of three rows
        @(negedge clk);load_start=1;@(negedge clk);load_start=0;
        wait(ready);if(!error)$fatal(1,"truncated BMP payload accepted");
        profile=0;w=7;h=3;stride=24;offset=54;length=126;
        @(negedge clk);scan_start=1;@(negedge clk);scan_start=0;
        wait(scan_done);repeat(2)@(negedge clk);
        if(total!=1 || seen!=1 || found_sector!=4)$fatal(1,"variable-size scan failed total=%0d seen=%0d found=%0d done=%0d",total,seen,found_sector,scan_done);
        $display("PASS tb_bmp_scaled: contain, padding, offset, stalls, identity, scan");$finish;
    end
    initial begin #300000000;$fatal(1,"TIMEOUT");end
endmodule

module tb_bmp_scaled_frame;
    tb_bmp_scaled #(.DW(640),.DH(480),.FULL(1)) raster();
endmodule
