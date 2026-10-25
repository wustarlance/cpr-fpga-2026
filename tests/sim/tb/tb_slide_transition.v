`timescale 1ns/1ps
module tb_slide_transition;
reg sdclk=0,vclk=0,mclk=0,rst=1,vs=1,de=0;
reg [23:0] rgb=0;
reg raw=0,smooth=0,mem_frame=0;
reg [1:0] requested_index=0;
wire fade_request,ready,publish,done,busy;
wire ov,od;
wire [23:0] out_rgb;
wire [4:0] gain;
wire [1:0] active_index;
always #5 sdclk=~sdclk;
always #20 vclk=~vclk;
always #12.5 mclk=~mclk;
cpr_transition_publish #(.GUARD_CYCLES(4000)) bridge(
    .clk(sdclk),.rst(rst),.publish_in(raw),.smooth_in(smooth),.publish_done(done),
    .fade_ready_async(ready),.fade_request(fade_request),.publish_out(publish));
cpr_slide_fade fade(.clk(vclk),.rst(rst),.request_async(fade_request),.vs(vs),.de(de),.rgb(rgb),
    .ready(ready),.out_vs(ov),.out_de(od),.out_rgb(out_rgb),.gain(gain));
frame_buffer_publish publisher(.src_clk(sdclk),.src_rst_n(!rst),.publish(publish),
    .buffer_index(requested_index),.busy(busy),.done(done),
    .mem_clk(mclk),.mem_rst_n(!rst),.frame_start(mem_frame),.active_index(active_index));
reg guard_raw=0,guard_done=0;
wire guard_request,guard_publish;
cpr_transition_publish #(.GUARD_CYCLES(12)) watchdog(
    .clk(sdclk),.rst(rst),.publish_in(guard_raw),.smooth_in(1'b1),.publish_done(guard_done),
    .fade_ready_async(1'b0),.fade_request(guard_request),.publish_out(guard_publish));
integer publishes=0,guard_publishes=0;
reg auto_check=0;
always @(posedge sdclk) begin
    #1;
    if(!rst && publish) begin
        publishes=publishes+1;
        if(auto_check && (!ready || gain!=0))$fatal(1,"automatic page published before black");
    end
    if(!rst && guard_publish)guard_publishes=guard_publishes+1;
end
task request_page;
    input integer index,effect;
    begin
        @(negedge sdclk);requested_index=index;smooth=effect;raw=1;
        @(negedge sdclk);raw=0;
        repeat(8)@(negedge sdclk);
    end
endtask
task frame;
    begin
        @(negedge vclk);vs=1;de=0;
        repeat(3)@(negedge vclk);vs=0;
        repeat(3)@(negedge vclk);vs=1;
        repeat(3)@(negedge vclk);
    end
endtask
task memory_boundary;
    begin
        // Give the real publisher time to synchronize the request first.
        repeat(8)@(negedge mclk);mem_frame=1;
        @(negedge mclk);mem_frame=0;
        wait(done);repeat(4)@(negedge sdclk);
    end
endtask
task pixel;
    input [23:0] value;
    input integer expected_gain;
    reg [23:0] wanted;
    integer r,g,b;
    begin
        r=(value[23:16]*expected_gain)/16;
        g=(value[15:8]*expected_gain)/16;
        b=(value[7:0]*expected_gain)/16;
        wanted={8'(r),8'(g),8'(b)};
        @(negedge vclk);rgb=value;de=1;
        repeat(2)@(posedge vclk);#1;
        if(out_rgb!==wanted || od!==1 || ov!==vs)
            $fatal(1,"fade pixel/sideband mismatch gain=%0d got=%h expected=%h",expected_gain,out_rgb,wanted);
        @(negedge vclk);de=0;
    end
endtask
integer i,j;
initial begin
    repeat(5)@(negedge vclk);rst=0;
    request_page(0,0);
    if(publishes!=1 || fade_request || gain!=16)$fatal(1,"initial publication faded");
    memory_boundary();
    pixel(24'hff8041,16);
    auto_check=1;request_page(1,1);
    for(i=1;i<=16;i=i+1)begin
        frame();
        if(gain!=16-i)$fatal(1,"fade-out step mismatch: %0d",gain);
        if(i<16 && (publishes!=1 || active_index!=0))$fatal(1,"page switched during fade-out");
        for(j=0;j<8;j=j+1)pixel({8'(j*31),8'(255-j*29),8'(j*17)},16-i);
    end
    repeat(10)@(negedge sdclk);
    if(publishes!=2 || active_index!=0 || !fade_request || !ready)$fatal(1,"black handshake missing");
    // Multiple frames may elapse before memory ACK: remain completely black.
    repeat(3)begin frame();pixel(24'hffffff,0);end
    if(gain!=0 || !fade_request)$fatal(1,"black was released before publication ACK");
    memory_boundary();
    if(active_index!=1 || fade_request)$fatal(1,"real frame publication did not finish");
    for(i=1;i<=16;i=i+1)begin
        frame();if(gain!=i)$fatal(1,"fade-in step mismatch");pixel(24'hff8143,i);
    end
    auto_check=0;request_page(2,0);
    if(publishes!=3 || fade_request || gain!=16)$fatal(1,"manual publication was delayed by fade");
    memory_boundary();if(active_index!=2)$fatal(1,"manual publication target");
    // No video/ready: bounded fallback emits one publication, no stuck black.
    @(negedge sdclk);guard_raw=1;@(negedge sdclk);guard_raw=0;
    repeat(30)@(negedge sdclk);
    if(guard_publishes!=1 || guard_request)$fatal(1,"no-VS watchdog did not recover");
    guard_done=1;repeat(3)@(negedge sdclk);guard_done=0;
    // Reset in mid-fade, then recover via an ordinary page publication.
    request_page(3,1);repeat(4)frame();
    @(negedge vclk);rst=1;repeat(3)@(negedge vclk);rst=0;
    if(gain!=16 || fade_request || busy || active_index!=0)$fatal(1,"reset retained a transition");
    request_page(3,0);memory_boundary();
    if(active_index!=3)$fatal(1,"publication did not recover after reset");
    $display("PASS: tb_slide_transition frame-boundary ACK, 16-step gain, watchdog and reset");$finish;
end
initial begin #300000;$fatal(1,"slide transition timeout");end
endmodule
