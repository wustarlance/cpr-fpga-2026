// Diagnostic implementation reproducer only. No SDRAM controller or bitgen.
module sdram_location_probe(input wire clk, output wire [3:0] status);
wire [31:0] dq;
EG_PHY_SDRAM_2M_32 sdram(
 .clk(clk),.ras_n(1'b1),.cas_n(1'b1),.we_n(1'b1),
 .addr(11'd0),.ba(2'd0),.dq(dq),.cs_n(1'b0),
 .dm0(1'b0),.dm1(1'b0),.dm2(1'b0),.dm3(1'b0),.cke(1'b1));
assign status=dq[3:0];
endmodule
