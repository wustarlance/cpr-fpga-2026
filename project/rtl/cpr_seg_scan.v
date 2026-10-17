`timescale 1ns/1ps
// 8 位动态扫描，用于板载两组 4 位一体共阳数码管。
//
// 05_lab_ex 里的 seg_scan 硬编码 6 位（scan_sel 0..5），而本板的 8 个位选
// SEL0..SEL7 都能用，SEL0/SEL1 原来没有约束所以最左两格一直不亮。这里改成
// 8 位，位号按物理顺序：seg_sel[0] = 左起第 1 位 … seg_sel[7] = 左起第 8 位。
// 约束文件里已经按这个顺序重新映射过，不要再用旧工程的位序。
//
// 共阳数码管：段码低电平点亮，位选高电平使能；seg_data 的 MSB 是小数点，
// 这里由调用方固定给 1（熄灭）。
module cpr_seg_scan #(
    parameter integer CLK_FREQ = 50_000_000,
    parameter integer SCAN_HZ  = 200            // 每秒一轮，8 位 → 每位 1/1600 s
)(
    input  wire       clk,
    input  wire       rst_n,
    output reg  [7:0] seg_sel,
    output reg  [7:0] seg_data,
    input  wire [7:0] digit0,
    input  wire [7:0] digit1,
    input  wire [7:0] digit2,
    input  wire [7:0] digit3,
    input  wire [7:0] digit4,
    input  wire [7:0] digit5,
    input  wire [7:0] digit6,
    input  wire [7:0] digit7
);
    localparam integer STEP = (CLK_FREQ / (SCAN_HZ * 8) > 1) ?
                              (CLK_FREQ / (SCAN_HZ * 8)) : 2;

    reg [31:0] scan_timer;
    reg [2:0]  scan_sel;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scan_timer <= 32'd0;
            scan_sel   <= 3'd0;
        end else if (scan_timer >= STEP - 1) begin
            scan_timer <= 32'd0;
            scan_sel   <= (scan_sel == 3'd7) ? 3'd0 : (scan_sel + 3'd1);
        end else begin
            scan_timer <= scan_timer + 32'd1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seg_sel  <= 8'hff;              // 位选高 = 全不使能
            seg_data <= 8'hff;              // 段码高 = 全灭
        end else begin
            case (scan_sel)
                3'd0: begin seg_sel <= 8'b1111_1110; seg_data <= digit0; end
                3'd1: begin seg_sel <= 8'b1111_1101; seg_data <= digit1; end
                3'd2: begin seg_sel <= 8'b1111_1011; seg_data <= digit2; end
                3'd3: begin seg_sel <= 8'b1111_0111; seg_data <= digit3; end
                3'd4: begin seg_sel <= 8'b1110_1111; seg_data <= digit4; end
                3'd5: begin seg_sel <= 8'b1101_1111; seg_data <= digit5; end
                3'd6: begin seg_sel <= 8'b1011_1111; seg_data <= digit6; end
                default: begin seg_sel <= 8'b0111_1111; seg_data <= digit7; end
            endcase
        end
    end
endmodule
