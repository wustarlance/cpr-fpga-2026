`timescale 1ns/1ps
module scroll_contract_checker #(
  parameter TL=32, GAP=4, FPP=3, XL=16, YT=448, WW=608
)(input wire clk,rst_n,frame_start,de,enable,scroll_enable,
  input wire [9:0] x,y, input wire use_rom,
  input wire [34:0] manual_glyph);
  localparam SPAN=(TL+GAP)*16;
  wire [5:0] addr;
  wire pixel;
  reg [7:0] ascii [0:31];
  reg [35:0] golden [0:255];
  wire [7:0] code=ascii[addr[4:0]];
  wire [34:0] rom_pixels;
  wire [34:0] glyph=use_rom ? rom_pixels : manual_glyph;
  font5x7_rom rom(.code(code),.pixels(rom_pixels));
  scroll_text #(.TEXT_LENGTH(TL),.GAP_CELLS(GAP),.FRAMES_PER_PIXEL(FPP),
    .X_LEFT(XL),.Y_TOP(YT),.WINDOW_WIDTH(WW)) dut(
    .clk(clk),.rst_n(rst_n),.frame_start(frame_start),.de(de),.x(x),.y(y),
    .enable(enable),.scroll_enable(scroll_enable),.text_addr(addr),
    .glyph_pixels(glyph),.text_pixel(pixel));
  integer accepted=0;
  integer expected_offset,p,index,gx,gy,expected_addr;
  reg expected_pixel;
  reg [34:0] expected_glyph;
  initial begin
    $readmemh("fixtures/scroll_text_ascii.mem",ascii);
    $readmemh("fixtures/glyph5x7_golden.mem",golden);
  end
  // One monotonically counted number of accepted frame events, followed by
  // division/modulo, is independent of the RTL's offset/phase registers.
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) accepted<=0;
    else if(enable && scroll_enable && frame_start) accepted<=accepted+1;
  end
  task check;
    begin
      expected_addr=0;expected_pixel=0;
      expected_offset=(accepted/FPP)%SPAN;
      if(rst_n && x>=XL && x<XL+WW && y>=YT && y<YT+16) begin
        p=(x-XL+expected_offset)%SPAN;
        index=p/16;gx=(p%16)/2;gy=(y-YT)/2;
        if(index<TL)begin
          expected_addr=index;
          expected_glyph=use_rom ? golden[ascii[index%32]][34:0] : manual_glyph;
          if(de && enable && gx<5 && gy<7)
            expected_pixel=expected_glyph[34-gy*5-gx];
        end
      end
      if(addr!==expected_addr[5:0] || pixel!==expected_pixel)
        $fatal(1,"SCROLL CONTRACT TL=%0d GAP=%0d FPP=%0d accepted=%0d offset=%0d x=%0d y=%0d addr=%0d/%0d pixel=%b/%b",TL,GAP,FPP,accepted,expected_offset,x,y,addr,expected_addr,pixel,expected_pixel);
    end
  endtask
endmodule

module tb_scroll_contract;
  reg clk=0,rst_n=1,frame_start=0,de=1,enable=1,scroll_enable=1,use_rom=0;
  reg [9:0] x=0,y=0;
  reg [34:0] manual_glyph=35'h7ffffffff;
  always #5 clk=~clk;
  scroll_contract_checker c0(.*);
  scroll_contract_checker #(.TL(1),.GAP(1),.FPP(1),.XL(0),.YT(0),.WW(640)) c1(.*);
  scroll_contract_checker #(.TL(64),.GAP(8),.FPP(1)) c2(.*);
  scroll_contract_checker #(.TL(7),.GAP(3),.FPP(2),.XL(13),.YT(91),.WW(37)) c3(.*);
  scroll_contract_checker #(.TL(1),.GAP(8),.FPP(255)) c4(.*);
  integer checks=0,frame_checks=0,xx,yy,i;
  task check_all;
    begin c0.check();c1.check();c2.check();c3.check();c4.check();checks=checks+5;end
  endtask
  task sample(input integer sx,input integer sy);
    begin x=sx;y=sy;#1;check_all();end
  endtask
  task sweep;
    begin
      // All columns, all active text rows plus both vertical clip edges;
      // other rows are blank and receive explicit endpoint probes.
      for(yy=0;yy<480;yy=yy+1)
        if(yy<=16 || (yy>=90 && yy<=107) || (yy>=447 && yy<=464) || yy==479)
          for(xx=0;xx<640;xx=xx+1)sample(xx,yy);
      sample(1023,0);sample(0,1023);sample(1023,1023);
    end
  endtask
  task probe;
    begin
      // Scan every column at each configured window's first glyph row.
      for(xx=0;xx<640;xx=xx+1)begin
        sample(xx,0);sample(xx,91);sample(xx,448);
      end
      // Check all vertical edge/spacing rows at horizontal edge locations.
      for(yy=0;yy<480;yy=yy+1)
        if(yy==1 || yy==12 || yy==13 || yy==14 || yy==15 || yy==16 ||
           yy==90 || yy==92 || yy==103 || yy==104 || yy==105 || yy==106 || yy==107 ||
           yy==447 || yy==449 || yy==460 || yy==461 || yy==462 || yy==463 || yy==464 || yy==479)begin
          sample(0,yy);sample(13,yy);sample(15,yy);sample(16,yy);sample(25,yy);
          sample(26,yy);sample(49,yy);sample(50,yy);sample(623,yy);sample(624,yy);sample(639,yy);
        end
      sample(1023,0);sample(0,1023);sample(1023,1023);
    end
  endtask
  task frame_event;
    begin
      @(negedge clk);frame_start=1;
      @(negedge clk);frame_start=0;
      #1;check_all();frame_checks=frame_checks+1;
    end
  endtask
  initial begin
    #1;rst_n=0;#11;check_all();rst_n=1;
    sweep();
    manual_glyph=35'h400000000;sweep();
    manual_glyph=35'h1;sweep();
    use_rom=1;sweep();use_rom=0;manual_glyph=35'h7ffffffff;
    // Pause at a partial frame phase; frame events must not be consumed.
    frame_event();frame_event();
    enable=0;repeat(11)frame_event();probe();enable=1;
    frame_event();probe();
    scroll_enable=0;repeat(13)frame_event();probe();scroll_enable=1;
    frame_event();frame_event();probe();
    de=0;probe();de=1;
    // Default: two COMPLETE offset cycles, 3 frames per pixel.
    // TL64/GAP8: the 11-bit counter crosses its full 1152-pixel span too.
    for(i=0;i<3500;i=i+1)begin
      sample(16+(i%608),448+(i%16));frame_event();
      if(i==252 || i==253 || i==254 || i==1150 || i==1151 || i==1725 || i==1726 || i==1727 || i==3454 || i==3455)probe();
    end
    use_rom=1;probe();
    // Async reset while visible; every configuration blanks immediately.
    sample(32,448);#2;rst_n=0;#1;check_all();probe();rst_n=1;#1;probe();
    repeat(25)@(negedge clk);#1;check_all();
    $display("PASS tb_scroll_contract checks=%0d frame_events=%0d",checks,frame_checks);$finish;
  end
  initial begin #20000000;$fatal(1,"tb_scroll_contract TIMEOUT");end
endmodule
