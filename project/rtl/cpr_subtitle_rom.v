// 32 ASCII characters per frame-selected mode. No external file required.
module cpr_subtitle_rom #(parameter UNCALIBRATED_PRESSURE=0)(
    input wire [1:0] mode,
    input wire [5:0] addr,
    output wire [7:0] code
);
    reg [255:0] message;
    always @(*) begin
        case(mode)
            0: message="CPR TEACH   LEARN THE BASICS    ";
            1: message="CPR AUTO   PRESS TO PAUSE       ";
            default: message=UNCALIBRATED_PRESSURE ? "CPR TRAIN   PRESS UNCAL         " : "CPR TRAIN   FOLLOW THE BEAT     ";
        endcase
    end
    assign code=addr<32 ? message[255-addr*8 -: 8] : 8'h20;
endmodule
