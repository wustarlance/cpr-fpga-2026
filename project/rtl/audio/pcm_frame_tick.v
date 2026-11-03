`timescale 1ns/1ps
// 音频帧节拍：每256个MCLK产生一拍O_frame_stb。
// pcm_player与heartbeat_synth共用该节拍，输出帧率为MCLK/256。
// 除数与HDMI音频配置配套；改变采样率时需同时核对MCLK和ACR。
module pcm_frame_tick (
    input  wire        I_mclk,        // 12.288 MHz（必须 = 256 × fs）
    input  wire        I_rst,         // 高有效，与音频域同一复位
    output reg         O_frame_stb    // 每 256 个 MCLK 一个单拍
);

localparam [7:0] DIV_LAST = 8'd255;   // 0..255 共 256 拍

reg [7:0] S_cnt;

always @(posedge I_mclk or posedge I_rst) begin
    if (I_rst) begin
        S_cnt       <= 8'd0;
        O_frame_stb <= 1'b0;
    end
    else begin
        O_frame_stb <= 1'b0;          // 默认 0，只在回绕那一拍拉高
        if (S_cnt == DIV_LAST) begin
            S_cnt       <= 8'd0;
            O_frame_stb <= 1'b1;
        end
        else begin
            S_cnt <= S_cnt + 8'd1;
        end
    end
end

endmodule
