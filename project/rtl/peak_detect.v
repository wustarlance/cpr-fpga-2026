`timescale 1ns/1ps
// One completion per trigger -> full release sequence, in the clk domain.
// Thresholds are uncalibrated pressure codes, not millimetres/centimetres.
module peak_detect #(
    parameter [11:0] TRIGGER_LEVEL = 12'd150,
    parameter [11:0] RELEASE_LEVEL = 12'd100,
    parameter [11:0] TARGET_LOW = 12'd800,
    parameter [11:0] TARGET_HIGH = 12'd1600
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enabled,
    input  wire        clear_session,
    input  wire        sample_valid,
    input  wire [11:0] sample_data,
    output reg         peak_valid,
    output reg  [11:0] peak_value,
    output reg  [1:0]  depth_grade,
    output reg         in_press
);
    reg armed;
    reg [11:0] active_peak;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            armed      <= 1'b0;
            active_peak <= 12'd0;
            peak_valid <= 1'b0;
            peak_value <= 12'd0;
            depth_grade <= 2'd0;
            in_press   <= 1'b0;
        end else begin
            // This default is independent of sample_valid. A completion
            // remains exactly one system clock even with sparse samples.
            peak_valid <= 1'b0;
            if (!enabled || clear_session) begin
                armed       <= 1'b0;
                active_peak <= 12'd0;
                peak_value  <= 12'd0;
                depth_grade <= 2'd0;
                in_press    <= 1'b0;
            end else if (sample_valid) begin
                if (!armed) begin
                    // A held sensor cannot create a new press after reset,
                    // clear or re-enable: first observe a full release.
                    if (sample_data <= RELEASE_LEVEL)
                        armed <= 1'b1;
                end else if (!in_press) begin
                    if (sample_data >= TRIGGER_LEVEL) begin
                        in_press <= 1'b1;
                        active_peak <= sample_data;
                    end
                end else if (sample_data <= RELEASE_LEVEL) begin
                    in_press <= 1'b0;
                    peak_valid <= 1'b1;
                    peak_value <= active_peak;
                    active_peak <= 12'd0;
                    if (active_peak < TARGET_LOW)
                        depth_grade <= 2'd1;
                    else if (active_peak <= TARGET_HIGH)
                        depth_grade <= 2'd2;
                    else
                        depth_grade <= 2'd3;
                end else if (sample_data > active_peak) begin
                    active_peak <= sample_data;
                end
            end
        end
    end
endmodule
