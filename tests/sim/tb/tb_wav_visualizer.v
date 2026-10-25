`timescale 1ns/1ps
module tb_wav_visualizer;
reg sdclk=0,mclk=0,vclk=0,rst=1,vs=1;
always #5 sdclk=~sdclk;
always #40.667 mclk=~mclk;
always #20 vclk=~vclk;
reg play=1,stop=0,mute=0,training_gate=1;
wire read_req,sd_ready,audio_valid,header_ready,audio_error;
wire [31:0] address;
reg [7:0] data;
reg valid=0,ending=0,busy=0,pace=0;
reg [7:0] bytes[0:16895];
integer pos=0,base=0,reads=0,nonzero=0,samples=0;
assign sd_ready=!busy;
always @(posedge sdclk)begin
 if(rst)begin busy<=0;valid<=0;ending<=0;pos<=0;pace<=0;end
 else begin
  valid<=0;ending<=0;
  if(!busy && read_req)begin
   if(address<12000 || address>12032)$fatal(1,"WAV read outside fixture: %0d",address);
   base=(address-12000)*512;pos<=0;busy<=1;pace<=0;reads=reads+1;
  end else if(busy)begin
   pace<=~pace;
   if(pace)begin
    if(pos<512)begin data<=bytes[base+pos];valid<=1;pos<=pos+1;end
    else begin ending<=1;busy<=0;end
   end
  end
 end
end
wire [23:0] left,right;
wav_audio_sd_top source(.I_sd_clk(sdclk),.I_mclk(mclk),.I_video_clk(vclk),
 .I_sd_rst(rst),.I_mclk_rst(rst),.I_video_rst(rst),
 .I_play(play),.I_stop(stop),.I_mute(mute),.I_loop(1'b0),
 .I_sd_init_done(!rst),.I_sd_sec_ready(sd_ready),.O_sd_sec_addr(address),.O_sd_sec_read(read_req),
 .I_sd_sec_data(data),.I_sd_sec_valid(valid),.I_sd_sec_end(ending),
 .O_audio_valid(audio_valid),.O_audio_left_data(left),.O_audio_right_data(right),
 .O_wav_ready(header_ready),.O_wav_error(audio_error));
wire [5:0] level;
wire waveform_valid;
// Exact top-level contract: apply the final training gate before BOTH sinks.
wire [23:0] gated_left=training_gate ? left : 24'd0;
wire [23:0] gated_right=training_gate ? right : 24'd0;
cpr_audio_visualizer visual(.clk(vclk),.rst(rst),.enable(1'b1),.vs(vs),.de(1'b0),.rgb(24'd0),
 .sample_valid(audio_valid),.sample_left(gated_left),.sample_right(gated_right),
 .out_vs(),.out_de(),.out_rgb(),.level(level),.waveform_valid(waveform_valid));
always @(posedge vclk)begin
 if(!rst && audio_valid)begin
  samples=samples+1;
  if(left!==0 || right!==0)begin
   if(!((left===24'h200000 && right===24'hc00000)||(left===24'he00000 && right===24'h400000)))
    $fatal(1,"WAV stereo PCM/sign/24-bit alignment failed: %h %h",left,right);
   nonzero=nonzero+1;
  end
 end
end
task frame;
 begin
  @(negedge vclk);vs=1;repeat(3)@(negedge vclk);vs=0;
  repeat(3)@(negedge vclk);vs=1;repeat(3)@(negedge vclk);
 end
endtask
integer before_samples,i;
initial begin
 $readmemh("fixtures/wav_stereo_visualizer.mem",bytes);
 repeat(8)@(negedge vclk);rst=0;
 // Probe the bundled-data contract directly: after SD commits the header,
 // changing the parser-side fields must not tear the in-flight snapshot.
 // This is a deliberate injection; today's parser normally retains them.
 wait(header_ready);wait(source.u_path.S_cfg_seen);
 @(negedge sdclk);
 force source.u_path.W_wav_sr=32'd44100;
 force source.u_path.W_wav_ftotal=32'd777;
 @(posedge mclk);
 while(!source.u_path.W_cfg_load)@(posedge mclk);
 #1;
 if(source.u_path.S_sr!==48000 || source.u_path.S_ftotal!==4096)
  $fatal(1,"WAV configuration snapshot was torn before destination capture");
 release source.u_path.W_wav_sr;
 release source.u_path.W_wav_ftotal;
 // Also exercise an actual stop/reparse, without injecting parser fields.
 @(negedge vclk);stop=1;
 @(negedge vclk);stop=0;
 #2000;
 if(source.u_path.S_sr!==48000 || source.u_path.S_cfg_rate_hold!==48000)
  $fatal(1,"WAV reset/reparse tore the in-flight configuration");
 wait(nonzero>=1100);frame();
 if(level!=32 || !waveform_valid)$fatal(1,"actual WAV did not drive stereo VU/scope");
 @(negedge vclk);training_gate=0;before_samples=samples;
 wait(samples>=before_samples+1030);
 // Keep PCM samples between frame boundaries. Back-to-back synthetic VS
 // pulses would correctly exercise the no-samples timeout instead of mute.
 repeat(10)begin #1000000;frame();end
 if(level!=0 || !waveform_valid)$fatal(1,"training gate did not produce visual silence");
 // The source's video-to-MCLK mute level must also settle to digital zero.
 @(negedge vclk);training_gate=1;mute=1;before_samples=samples;
 wait(samples>=before_samples+4);
 for(i=0;i<8;i=i+1)begin
  @(negedge vclk);wait(audio_valid);#1;
  if(left!==0 || right!==0)$fatal(1,"synchronized WAV mute did not silence PCM");
  wait(!audio_valid);
 end
 @(negedge vclk);mute=0;before_samples=nonzero;
 wait(nonzero>=before_samples+32);frame();
 if(level!=32)$fatal(1,"unmute did not recover actual WAV VU");
 if(audio_error)$fatal(1,"WAV transport error");
 $display("PASS: tb_wav_visualizer actual WAV/PCM/VU, config snapshot, mute and training gate; reads=%0d samples=%0d",reads,samples);$finish;
end
initial begin #120000000;$fatal(1,"WAV visualizer timeout");end
endmodule
