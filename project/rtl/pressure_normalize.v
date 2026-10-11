`timescale 1ns/1ps
// ADC codes -> non-negative pressure codes. No displacement calibration implied.
// All ports belong to clk; reset assertion is asynchronous, release must be
// synchronized by the owner of this clock domain.
module pressure_normalize #(
    parameter [11:0] RELEASE_BASELINE = 12'd3000,
    parameter integer FALLING_WITH_FORCE = 1,
    parameter integer FILTER_SHIFT = 2
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        adc_valid,
    input  wire [11:0] adc_data,
    output reg         pressure_valid,
    output reg  [11:0] pressure_data
);

    wire [11:0] force_sample;
    assign force_sample = FALLING_WITH_FORCE ?
        ((adc_data < RELEASE_BASELINE) ? RELEASE_BASELINE - adc_data : 12'd0) :
        ((adc_data > RELEASE_BASELINE) ? adc_data - RELEASE_BASELINE : 12'd0);

    generate
        if (FILTER_SHIFT == 0) begin : g_no_filter
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    pressure_valid <= 1'b0;
                    pressure_data  <= 12'd0;
                end else begin
                    pressure_valid <= adc_valid;
                    if (adc_valid)
                        pressure_data <= force_sample;
                end
            end
        end else if (FILTER_SHIFT == 2) begin : g_average
            localparam integer WINDOW_SIZE = 4;
            localparam integer SUM_WIDTH = 14;
            reg [11:0] history [0:WINDOW_SIZE-1];
            reg [1:0] write_index;
            reg [2:0] sample_count;
            reg [SUM_WIDTH-1:0] sum;
            wire [SUM_WIDTH-1:0] old_sample_ext;
            wire [SUM_WIDTH-1:0] new_sample_ext;
            wire [SUM_WIDTH-1:0] sum_next;
            integer i;

            assign old_sample_ext = {2'b00, history[write_index]};
            assign new_sample_ext = {2'b00, force_sample};
            assign sum_next = sum - old_sample_ext + new_sample_ext;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    pressure_valid <= 1'b0;
                    pressure_data  <= 12'd0;
                    write_index    <= 2'd0;
                    sample_count   <= 3'd0;
                    sum            <= {SUM_WIDTH{1'b0}};
                    for (i = 0; i < WINDOW_SIZE; i = i + 1)
                        history[i] <= 12'd0;
                end else begin
                    pressure_valid <= 1'b0;
                    if (adc_valid) begin
                        history[write_index] <= force_sample;
                        write_index <= write_index + 1'b1;
                        sum <= sum_next;
                        if (sample_count < WINDOW_SIZE)
                            sample_count <= sample_count + 1'b1;
                        // Require a complete window. Invalid cycles do not
                        // enter the average and do not affect warm-up.
                        if (sample_count >= WINDOW_SIZE - 1) begin
                            pressure_data <= sum_next >> 2;
                            pressure_valid <= 1'b1;
                        end
                    end
                end
            end
        end else begin : g_invalid_filter_shift
            // Deliberately undefined: unsupported values fail elaboration,
            // rather than silently selecting a different transfer function.
            PRESSURE_NORMALIZE_FILTER_SHIFT_MUST_BE_0_OR_2 parameter_error();
        end
    endgenerate
endmodule
