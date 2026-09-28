`timescale 1ns/1ps
module tb_adc;
  reg clk = 0, pd = 0, soc = 0;  reg [2:0] s = 3'd1;
  wire eoc;  wire [11:0] dout;
  always #5 clk = ~clk;                    // 100 MHz
  EG_PHY_ADC #(.CH1("ENABLE")) u_adc (
      .clk(clk), .pd(pd), .s(s), .soc(soc), .eoc(eoc), .dout(dout));
  integer i, n = 0;
  initial begin
    $dumpfile("tb_adc.vcd"); $dumpvars(0, tb_adc);
    @(negedge clk);
    for (i = 0; i < 12; i = i + 1) begin
      @(negedge clk) soc = 1;
      @(negedge clk) soc = 0;
      repeat (40) @(posedge clk);
      if (eoc) begin n = n + 1;
        $display("[%0t] eoc=1  dout=%0d (0x%03h)", $time, dout, dout); end
    end
    $display("--- 收到 %0d 次 eoc ---", n);
    $finish;
  end
  initial begin #200000; $display("TIMEOUT"); $finish; end
endmodule
