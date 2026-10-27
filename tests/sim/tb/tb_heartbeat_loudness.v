`timescale 1ns/1ps
module tb_heartbeat_loudness;
    reg clk=0,rst=1,enable=0,stb=0;
    always #5 clk=~clk;
    integer divider=0,n=0;
    always @(posedge clk)begin
        divider<=divider==3 ? 0 : divider+1;
        stb<=divider==3;
    end
    wire [23:0] old_l,old_r,loud_l,loud_r;
    wire old_busy,loud_busy;
    heartbeat_synth #(.BOOST_DECAY(0)) original(
        .I_clk(clk),.I_rst(rst),.I_enable(enable),.I_frame_stb(stb),
        .O_left(old_l),.O_right(old_r),.O_busy(old_busy));
    heartbeat_synth louder(
        .I_clk(clk),.I_rst(rst),.I_enable(enable),.I_frame_stb(stb),
        .O_left(loud_l),.O_right(loud_r),.O_busy(loud_busy));
    reg capture=0;
    reg signed [63:0] energy_old=0,energy_loud=0,a,b;
    integer peak_old=0,peak_loud=0,raised=0;
    function integer magnitude;
        input [23:0] value;
        integer signed_value;
        begin signed_value=$signed(value);magnitude=signed_value<0 ? -signed_value : signed_value;end
    endfunction
    always @(posedge clk) if(!rst && stb)begin
        #1;
        if(old_busy!==loud_busy)$fatal(1,"heartbeat timing/busy changed");
        if(loud_l!==loud_r)$fatal(1,"heartbeat stereo mismatch");
        if(magnitude(loud_l)>8388352)$fatal(1,"heartbeat exceeded original digital peak");
        if(magnitude(loud_l)<magnitude(old_l))$fatal(1,"boost reduced a heartbeat sample");
        if(old_l===0 && loud_l!==0)$fatal(1,"silence or zero crossing changed");
        if(old_l!==0 && old_l[23]!==loud_l[23])$fatal(1,"heartbeat sign wrapped");
        if(capture)begin
            a=$signed(old_l);b=$signed(loud_l);
            energy_old=energy_old+a*a;energy_loud=energy_loud+b*b;
            if(magnitude(old_l)>peak_old)peak_old=magnitude(old_l);
            if(magnitude(loud_l)>peak_loud)peak_loud=magnitude(loud_l);
            if(magnitude(loud_l)>magnitude(old_l))raised=raised+1;
            n=n+1;
        end
    end
    integer before_n;
    initial begin
        repeat(8)@(negedge clk);rst=0;
        repeat(10)@(negedge clk);
        if(old_l!==0 || loud_l!==0)$fatal(1,"disabled heartbeat not silent");
        enable=1;capture=1;
        wait(n>=52364);@(negedge clk);capture=0;
        if(energy_old<=0 || energy_loud*10<energy_old*13)
            $fatal(1,"heartbeat energy did not increase sufficiently: old=%0d new=%0d",energy_old,energy_loud);
        if(energy_loud>energy_old*4)$fatal(1,"unexpected energy overflow/gain");
        if(peak_loud>8388352 || peak_loud<peak_old)$fatal(1,"peak policy failed");
        if(raised<1000)$fatal(1,"not enough louder samples");
        enable=0;
        repeat(500)@(negedge clk);
        if(loud_busy!==0 || loud_l!==0 || loud_r!==0)$fatal(1,"heartbeat release failed");
        $display("PASS: heartbeat_loudness frames=%0d energy_old=%0d energy_loud=%0d peak_old=%0d peak_loud=%0d raised=%0d",n,energy_old,energy_loud,peak_old,peak_loud,raised);
        $finish;
    end
    initial begin #5000000;$fatal(1,"heartbeat loudness TIMEOUT");end
endmodule
