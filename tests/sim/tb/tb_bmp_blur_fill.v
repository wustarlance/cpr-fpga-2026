`timescale 1ns/1ps
// Independent integer reference model. The expected image is generated from
// source coordinates, never by sampling DUT memories or implementation state.
// The source and destination raster orders here are both BMP bottom-up; a PPM
// dump reverses rows so an ordinary image viewer displays the HDMI orientation.
module tb_bmp_blur_fill #(parameter DW=16, DH=12, FULL=0);
    reg clk=0, rst=1, load_start=0, ack=0, pixel_ready=0;
    reg cancel=0, sd_error=0, sd_valid=0, sd_end=0;
    reg [7:0] sd_data=0;
    always #5 clk=~clk;
    wire ready, request, push, sd_read, error, abort_sd, operation_error;
    wire [2:0] error_code;
    wire [31:0] sd_addr;
    wire [23:0] pixel;
    integer w=16,h=12,offset=54,stride=48,length=630;
    integer fw,fh,left,bottom,crop_w,crop_h,crop_x,crop_y,bw,bh;
    integer count=0,cycle=0,requests=0,write_events=0,payload_starts=0;
    integer foreground_requests=0,case_id=0,profile=0;
    integer fault_phase=0,fault_kind=0;
    reg fault_fired=0,checking=0,previous_request=0;
    reg [31:0] rng=32'h381afb72;
    reg [23:0] expected_frame[0:DW*DH-1];
    reg [23:0] actual_frame[0:DW*DH-1];
    integer sums_r[0:767],sums_g[0:767],sums_b[0:767],samples[0:767];
    integer bg_r[0:767],bg_g[0:767],bg_b[0:767];
    integer tmp_r[0:767],tmp_g[0:767],tmp_b[0:767];
    reg [23:0] source_mem[0:65535];
    reg use_source_mem=0;
    reg [1023:0] source_path,ppm_path;
    integer preview_w=256,preview_h=256;

    bmp_read_scaled #(.DST_WIDTH(DW),.DST_HEIGHT(DH),
        .BLUR_BACKGROUND(1),.BG_BRIGHTNESS_NUM(3),.BG_BRIGHTNESS_SHIFT(2),
        .WAIT_TIMEOUT_CYCLES(1000000)) dut(
        .clk(clk),.rst(rst),.cancel(cancel),.sd_sec_ready(!rst),
        .sd_sec_read_error(sd_error),.abort_sd(abort_sd),
        .operation_error(operation_error),.error_code(error_code),.ready(ready),
        .scan_start(1'b0),.scan_start_sector(32'd4),.scan_max_sector(32'd4),
        .scan_target_count(3'd4),.scan_done(),.scan_found_valid(),
        .scan_found_sector(),.scan_found_total(),.load_start(load_start),
        .load_sector(32'd4),.sd_init_done(!rst),.state_code(),
        .bmp_width(DW[15:0]),.bmp_height(DH[15:0]),.write_req(request),
        .write_req_ack(ack),.sd_sec_read(sd_read),.sd_sec_read_addr(sd_addr),
        .sd_sec_read_data(sd_data),.sd_sec_read_data_valid(sd_valid),
        .sd_sec_read_end(sd_end),.bmp_data_wr_en(push),.bmp_data(pixel),
        .pixel_ready(pixel_ready),.load_error(error));

    function [23:0] source_pixel;
        input integer x,y;
        reg [7:0] r,g,b;
        begin
            if(use_source_mem) source_pixel=source_mem[y*w+x];
            else begin
                case(profile)
                    1: begin r=227;g=118;b=43;end
                    2: begin
                        r=((x/3+y/5)%2)?255:0;
                        g=(x<w/2)?17:239;b=(y<h/2)?248:9;
                    end
                    default: begin r=x*17+y*9;g=x*3+y*21;b=x*13+y*5;end
                endcase
                source_pixel={r,g,b};
            end
        end
    endfunction
    function [7:0] file_byte;
        input integer pos;
        integer n,x,y,c;
        reg [23:0] p;
        begin
            file_byte=0;
            case(pos)
                0:file_byte="B";1:file_byte="M";
                2:file_byte=length;3:file_byte=length>>8;
                4:file_byte=length>>16;5:file_byte=length>>24;
                10:file_byte=offset;11:file_byte=offset>>8;
                12:file_byte=offset>>16;13:file_byte=offset>>24;
                14:file_byte=40;
                18:file_byte=w;19:file_byte=w>>8;20:file_byte=w>>16;21:file_byte=w>>24;
                22:file_byte=h;23:file_byte=h>>8;24:file_byte=h>>16;25:file_byte=h>>24;
                26:file_byte=1;28:file_byte=24;
                default: if(pos>=offset && pos<length)begin
                    n=pos-offset;y=n/stride;x=(n%stride)/3;c=(n%stride)%3;
                    p=source_pixel(x,y);
                    file_byte=(n%stride>=w*3)?8'hee:(p>>(8*c));
                end
            endcase
        end
    endfunction

    // Consecutive source bytes are unstallable, with deterministic gaps around
    // pixel and sector boundaries. Both passes use exactly the same SD model.
    integer sd_i,base;
    reg stop_transfer,inject_this_request;
    initial forever begin
        wait(sd_read && !rst);
        base=(sd_addr-4)*512;requests=requests+1;
        if(requests>1 && sd_addr==4+(offset>>9))payload_starts=payload_starts+1;
        if(write_events!=0)foreground_requests=foreground_requests+1;
        inject_this_request=!fault_fired && fault_phase!=0 &&
            ((fault_phase==1 && write_events==0 && requests>=3) ||
             (fault_phase==2 && write_events!=0 && foreground_requests>=2));
        stop_transfer=0;
        for(sd_i=0;sd_i<512;sd_i=sd_i+1)begin
            @(negedge clk);
            if(abort_sd || !sd_read)stop_transfer=1;
            if(inject_this_request && sd_i==101)begin
                fault_fired=1;stop_transfer=1;
                if(fault_kind==1)sd_error=1;else cancel=1;
            end
            sd_valid=!stop_transfer;sd_data=file_byte(base+sd_i);
            if(stop_transfer)sd_i=512;
            else if(sd_i%71==17)begin @(negedge clk);sd_valid=0;end
        end
        @(negedge clk);sd_valid=0;sd_error=0;cancel=0;
        if(!stop_transfer)begin
            repeat(3)@(negedge clk);
            sd_end=1;@(negedge clk);sd_end=0;
        end
        wait(!sd_read);
    end
    // Real frame writer clears its FIFO while ACK remains high.
    initial forever begin
        wait(request);repeat(7)@(negedge clk);ack=1;
        wait(!request);repeat(8)@(negedge clk);ack=0;
    end
    always @(negedge clk)begin
        cycle=cycle+1;
        rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        pixel_ready=rng[0] && (cycle%257<190);
    end
    // OUT_SEND holds its data for arbitrary FIFO stalls. This is a protocol
    // property; expected pixel values below come only from the reference model.
    reg stalled=0;
    reg [23:0] stalled_pixel;
    always @(posedge clk)if(!rst)begin
        if(request && !previous_request)begin
            write_events=write_events+1;
            if(write_events!=1)$fatal(1,"case %0d duplicate write_req",case_id);
        end
        previous_request=request;
        if(stalled && dut.state==dut.OUT_SEND && !fault_fired && pixel!==stalled_pixel)
            $fatal(1,"case %0d data changed while backpressured",case_id);
        stalled=(dut.state==dut.OUT_SEND && !pixel_ready && !fault_fired);
        if(stalled)stalled_pixel=pixel;
        if(push)begin
            if(!checking)$fatal(1,"unexpected output between loads");
            if(ack)$fatal(1,"pixel emitted while frame FIFO clearing");
            if(write_events!=1)$fatal(1,"pixel before frame write handshake");
            if(count>=DW*DH)$fatal(1,"too many pixels case %0d",case_id);
            if(pixel!==expected_frame[count])$fatal(1,
                "case %0d %0dx%0d pixel %0d (%0d,%0d) got=%h expected=%h",
                case_id,w,h,count,count%DW,count/DW,pixel,expected_frame[count]);
            actual_frame[count]=pixel;count=count+1;
        end
    end

    task prepare_reference;
        integer x,y,bx,by,k,pass,nx,ny,dx,dy,idx,sr,sg,sb;
        integer qx,qy,x0,y0,x1,y1,fx,fy,a,b,c,d,r,g,bl;
        reg [23:0] p;
        begin
            if(w*DH>=h*DW)begin
                fw=DW;fh=(h*DW+w/2)/w;if(fh<1)fh=1;
                crop_w=h*DW/DH;if(crop_w<1)crop_w=1;crop_h=h;
            end else begin
                fh=DH;fw=(w*DH+h/2)/h;if(fw<1)fw=1;
                crop_w=w;crop_h=w*DH/DW;if(crop_h<1)crop_h=1;
            end
            left=(DW-fw)/2;bottom=(DH-fh+1)/2;
            crop_x=(w-crop_w)/2;crop_y=(h-crop_h+1)/2;
            bw=(crop_w<32)?crop_w:32;bh=(crop_h<24)?crop_h:24;
            for(k=0;k<768;k=k+1)begin
                sums_r[k]=0;sums_g[k]=0;sums_b[k]=0;samples[k]=0;
                bg_r[k]=0;bg_g[k]=0;bg_b[k]=0;
            end
            // Explicit area buckets, including all source pixels within the
            // integer centred cover crop. Each bucket has at least one sample.
            for(y=crop_y;y<crop_y+crop_h;y=y+1)begin
                for(x=crop_x;x<crop_x+crop_w;x=x+1)begin
                    bx=(x-crop_x)*bw/crop_w;by=(y-crop_y)*bh/crop_h;idx=by*bw+bx;
                    p=source_pixel(x,y);sums_r[idx]=sums_r[idx]+p[23:16];
                    sums_g[idx]=sums_g[idx]+p[15:8];sums_b[idx]=sums_b[idx]+p[7:0];
                    samples[idx]=samples[idx]+1;
                end
            end
            for(k=0;k<bw*bh;k=k+1)begin
                if(samples[k]==0)$fatal(1,"reference empty area bucket");
                bg_r[k]=sums_r[k]/samples[k];bg_g[k]=sums_g[k]/samples[k];
                bg_b[k]=sums_b[k]/samples[k];
            end
            for(pass=0;pass<3;pass=pass+1)begin
                for(y=0;y<bh;y=y+1)for(x=0;x<bw;x=x+1)begin
                    sr=0;sg=0;sb=0;
                    for(dy=-1;dy<=1;dy=dy+1)for(dx=-1;dx<=1;dx=dx+1)begin
                        nx=x+dx;ny=y+dy;
                        if(nx<0)nx=0;if(nx>=bw)nx=bw-1;
                        if(ny<0)ny=0;if(ny>=bh)ny=bh-1;idx=ny*bw+nx;
                        sr=sr+bg_r[idx];sg=sg+bg_g[idx];sb=sb+bg_b[idx];
                    end
                    idx=y*bw+x;tmp_r[idx]=sr/9;tmp_g[idx]=sg/9;tmp_b[idx]=sb/9;
                end
                for(k=0;k<bw*bh;k=k+1)begin
                    bg_r[k]=tmp_r[k];bg_g[k]=tmp_g[k];bg_b[k]=tmp_b[k];
                end
            end
            for(y=0;y<DH;y=y+1)for(x=0;x<DW;x=x+1)begin
                if(x>=left && x<left+fw && y>=bottom && y<bottom+fh)
                    p=source_pixel((x-left)*w/fw,(y-bottom)*h/fh);
                else begin
                    // Centre aligned bilinear coordinates represented in Q8.
                    qx=((2*x+1)*bw*256)/(2*DW)-128;
                    qy=((2*y+1)*bh*256)/(2*DH)-128;
                    if(qx<0)qx=0;if(qx>(bw-1)*256)qx=(bw-1)*256;
                    if(qy<0)qy=0;if(qy>(bh-1)*256)qy=(bh-1)*256;
                    x0=qx/256;y0=qy/256;fx=qx%256;fy=qy%256;
                    x1=(x0<bw-1)?x0+1:x0;y1=(y0<bh-1)?y0+1:y0;
                    a=y0*bw+x0;b=y0*bw+x1;c=y1*bw+x0;d=y1*bw+x1;
                    r=(bg_r[a]*(256-fx)*(256-fy)+bg_r[b]*fx*(256-fy)+
                       bg_r[c]*(256-fx)*fy+bg_r[d]*fx*fy+32768)/65536;
                    g=(bg_g[a]*(256-fx)*(256-fy)+bg_g[b]*fx*(256-fy)+
                       bg_g[c]*(256-fx)*fy+bg_g[d]*fx*fy+32768)/65536;
                    bl=(bg_b[a]*(256-fx)*(256-fy)+bg_b[b]*fx*(256-fy)+
                        bg_b[c]*(256-fx)*fy+bg_b[d]*fx*fy+32768)/65536;
                    r=r*3/4;g=g*3/4;bl=bl*3/4;p={r[7:0],g[7:0],bl[7:0]};
                end
                expected_frame[y*DW+x]=p;
            end
        end
    endtask
    task begin_image;
        input integer iw,ih,io,ip;
        begin
            wait(ready && !ack && !sd_read);repeat(2)@(negedge clk);
            w=iw;h=ih;offset=io;profile=ip;stride=(w*3+3)&~3;length=offset+stride*h;
            prepare_reference;
            count=0;requests=0;write_events=0;payload_starts=0;foreground_requests=0;
            previous_request=0;stalled=0;fault_fired=0;case_id=case_id+1;checking=1;
            @(negedge clk);load_start=1;@(negedge clk);load_start=0;
        end
    endtask
    task await_completion;
        integer timeout;
        begin
            timeout=0;
            while(!ready)begin
                @(negedge clk);timeout=timeout+1;
                if(timeout>20000000)$fatal(1,"case %0d timeout state=%0d",case_id,dut.state);
            end
            repeat(2)@(negedge clk);checking=0;
        end
    endtask
    task run_image;
        input integer iw,ih,io,ip;
        integer wanted_passes;
        begin
            fault_phase=0;fault_kind=0;begin_image(iw,ih,io,ip);await_completion;
            if(error || count!=DW*DH || write_events!=1)$fatal(1,
                "case %0d incomplete error=%0d count=%0d writes=%0d",case_id,error,count,write_events);
            wanted_passes=(fw!=DW || fh!=DH)?2:1;
            if(payload_starts!=wanted_passes)$fatal(1,
                "case %0d expected %0d payload passes got %0d requests=%0d",
                case_id,wanted_passes,payload_starts,requests);
            $display("PASS blur case %0d %0dx%0d offset=%0d profile=%0d passes=%0d",
                case_id,w,h,offset,profile,payload_starts);
        end
    endtask
    task run_fault;
        input integer phase,kind;
        begin
            fault_phase=phase;fault_kind=kind;begin_image(41,23,54,2);await_completion;
            if(!fault_fired || !error)$fatal(1,"fault phase=%0d kind=%0d not reported",phase,kind);
            if(error_code!=(kind==1?1:3))$fatal(1,"fault wrong error code=%0d",error_code);
            if(phase==1 && (count!=0 || write_events!=0))$fatal(1,"background fault exposed frame");
            if(phase==2 && count>=DW*DH)$fatal(1,"foreground fault completed invalid frame");
            $display("PASS injected fault phase=%0d kind=%0d writes=%0d pixels=%0d",
                phase,kind,write_events,count);
            repeat(30)@(negedge clk);
            // Changing the source pattern also detects stale thumbnail state
            // surviving a cancellation or failed SD transaction.
            run_image(41,23,54,kind==1?0:1);
        end
    endtask
    task run_filter_cancel;
        integer timeout;
        begin
            fault_phase=0;fault_kind=0;begin_image(83,83,54,2);
            timeout=0;
            while(dut.state!=dut.BG_WAIT)begin
                @(negedge clk);timeout=timeout+1;
                if(timeout>1000000)$fatal(1,"never reached background filtering");
            end
            repeat(100)@(negedge clk);
            if(write_events!=0 || count!=0)$fatal(1,"filtering exposed partial frame");
            @(negedge clk);cancel=1;fault_fired=1;
            @(negedge clk);cancel=0;
            await_completion;
            if(!error || error_code!=3 || write_events!=0 || count!=0)
                $fatal(1,"filter cancellation did not invalidate operation");
            $display("PASS cancellation during background filtering");
            repeat(30)@(negedge clk);run_image(83,83,54,1);
        end
    endtask
    task write_ppm;
        integer fd,x,y;reg [23:0] p;
        begin
            fd=$fopen(ppm_path,"w");if(fd==0)$fatal(1,"cannot open preview PPM");
            $fwrite(fd,"P3\n%0d %0d\n255\n",DW,DH);
            // Monitor has already compared every actual output to this frame.
            for(y=DH-1;y>=0;y=y-1)begin
                for(x=0;x<DW;x=x+1)begin
                    p=actual_frame[y*DW+x];$fwrite(fd,"%0d %0d %0d ",p[23:16],p[15:8],p[7:0]);
                end
                $fwrite(fd,"\n");
            end
            $fclose(fd);$display("Wrote verified RTL preview %0s",ppm_path);
        end
    endtask
    initial begin
        if($value$plusargs("SOURCE_MEM=%s",source_path))begin
            use_source_mem=1;$readmemh(source_path,source_mem);
            if(!$value$plusargs("SOURCE_WIDTH=%d",preview_w))preview_w=256;
            if(!$value$plusargs("SOURCE_HEIGHT=%d",preview_h))preview_h=256;
            if(preview_w*preview_h>65536)$fatal(1,"preview source exceeds 65536 pixels");
        end
        repeat(5)@(negedge clk);rst=0;
        if(FULL)begin
            if(use_source_mem)run_image(preview_w,preview_h,54,0);
            else run_image(83,83,54,2);
            if($value$plusargs("PPM=%s",ppm_path))write_ppm;
            $display("PASS tb_bmp_blur_fill_frame: verified full 640x480 composite");$finish;
        end
        run_image(16,12,54,0);run_image(8,6,54,2);run_image(32,24,54,0);
        run_image(7,7,54,0);run_image(83,83,54,2);run_image(7,13,54,0);
        run_image(17,9,54,2);run_image(100,31,54,0);run_image(17,13,54,0);
        run_image(1,29,54,1);run_image(59,1,600,0);run_image(33,33,600,1);
        run_fault(1,1);run_fault(2,1);run_fault(1,2);run_fault(2,2);
        run_filter_cancel;
        $display("PASS tb_bmp_blur_fill: pixel model, RGB rounding, crop, backpressure, faults and retries");
        $finish;
    end
    initial begin #1000000000;$fatal(1,"TIMEOUT blur fill");end
endmodule

module tb_bmp_blur_fill_frame;
    tb_bmp_blur_fill #(.DW(640),.DH(480),.FULL(1)) raster();
endmodule
