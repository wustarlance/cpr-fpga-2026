`timescale 1ns/1ps
module tb_chinese_rom;
    reg [7:0] code;
    reg [3:0] row;
    reg [5:0] message_id,index;
    wire [15:0] bits;
    wire [7:0] text_code;
    reg [255:0] golden[0:129];
    reg [7:0] messages[0:1375];
    integer c,r,m,i;
    cpr_font16_rom font(.code(code),.row(row),.row_bits(bits));
    cpr_zh_strings strings(.message_id(message_id),.index(index),.code(text_code));
    initial begin
        $readmemh("fixtures/chinese_glyphs.mem",golden);
        $readmemh("fixtures/chinese_messages.mem",messages);
        for(c=0;c<256;c=c+1)for(r=0;r<16;r=r+1)begin
            code=c;row=r;#1;
            if(bits !== (c<130 ? golden[c][255-r*16 -:16] : 16'd0))$fatal(1,"Chinese glyph row mismatch id=%0d row=%0d",c,r);
        end
        for(m=0;m<64;m=m+1)for(i=0;i<64;i=i+1)begin
            message_id=m;index=i;#1;
            if(text_code !== ((m<43 && i<32) ? messages[m*32+i] : 8'd0))$fatal(1,"Chinese message mismatch id=%0d index=%0d",m,i);
        end
        $display("PASS: tb_chinese_rom");$finish;
    end
    initial begin #100000;$fatal(1,"TIMEOUT Chinese ROM");end
endmodule
