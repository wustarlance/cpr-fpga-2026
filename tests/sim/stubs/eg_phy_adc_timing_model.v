`timescale 1ns / 1ps
// Original functional timing model, not a replacement for a vendor primitive.
// Mirrors the public model's 4 sampling / 16 completion clock boundaries.
// analog_code is a test stimulus word, not an analog voltage conversion model.
module eg_phy_adc_timing_model (
    input  wire        clk,
    input  wire        pd,
    input  wire [2:0]  s,
    input  wire        soc,
    input  wire [11:0] analog_code,
    output reg         eoc,
    output reg  [11:0] dout
);
    reg [4:0] counter;
    reg [11:0] sampled_code;

    always @(posedge clk or posedge pd) begin
        if (pd) begin
            counter <= 5'd0;
            sampled_code <= 12'hxxx;
            eoc <= 1'b0;
            dout <= 12'd0;
        end else begin
            eoc <= 1'b0;
            if (((counter == 0) || (counter == 16)) && soc)
                counter <= 5'd1;
            else if ((counter >= 1) && (counter < 16))
                counter <= counter + 1'b1;
            else
                counter <= 5'd0;

            // SOC is accepted at counter=0; four subsequent clock edges end
            // acquisition. Changes after this edge cannot change the result.
            if (counter == 4) begin
                if ((^s === 1'bx) || (^analog_code === 1'bx))
                    sampled_code <= 12'hxxx;
                else
                    sampled_code <= analog_code;
            end
            if (counter == 16) begin
                eoc <= 1'b1;
                dout <= sampled_code;
            end
        end
    end
endmodule
