// Single-clock EG4S20 ADC request/completion controller. No ADC primitive here.
// clk, adc_eoc and adc_dout must all belong to the same ADC clock domain.
module adc_ctrl #(
    parameter integer ADC_CLK_HZ = 12295082,
    parameter integer SAMPLE_HZ = 200000,
    parameter integer CHANNEL = 1,
    parameter integer TIMEOUT_CYCLES = 64
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        adc_eoc,
    input  wire [11:0] adc_dout,
    output reg         adc_soc,
    output reg         adc_pd,
    output wire [2:0]  adc_channel,
    output reg         sample_valid,
    output reg  [11:0] sample_data,
    output reg         fault
);
    function integer count_width;
        input integer value;
        integer remaining;
        begin
            remaining = value - 1;
            count_width = 0;
            while (remaining > 0) begin
                remaining = remaining >> 1;
                count_width = count_width + 1;
            end
            if (count_width < 1)
                count_width = 1;
        end
    endfunction

    // Constant division only: the frequency parameter does not create a clock.
    // Round the requested interval to the nearest whole ADC clock period.
    localparam integer REQUEST_CYCLES = (SAMPLE_HZ > 0) ?
        ((ADC_CLK_HZ + SAMPLE_HZ / 2) / SAMPLE_HZ) : 6;
    localparam integer PERIOD_CYCLES = (REQUEST_CYCLES >= 6) ?
        REQUEST_CYCLES : 6;
    localparam integer PERIOD_WIDTH = count_width(PERIOD_CYCLES);
    localparam integer WAIT_WIDTH = count_width(TIMEOUT_CYCLES + 1);
    // ceil(10 us * ADC_CLK_HZ), avoiding a large run-time multiplication.
    localparam integer SPARSE_LIMIT = (ADC_CLK_HZ + 99999) / 100000;
    localparam integer SPARSE = PERIOD_CYCLES >= SPARSE_LIMIT;
    // This registered controller needs 18 clocks to receive a 16-clock model
    // result. The primitive's published 1 MS/s maximum is not this wrapper's
    // guaranteed throughput at every clock frequency.
    localparam integer CONFIG_VALID =
        (ADC_CLK_HZ > 0) && (ADC_CLK_HZ <= 16000000) &&
        (SAMPLE_HZ > 0) && (SAMPLE_HZ <= 1000000) &&
        (REQUEST_CYCLES >= 18) && (!SPARSE || REQUEST_CYCLES >= 23) &&
        (TIMEOUT_CYCLES >= 18) &&
        (CHANNEL >= 0) && (CHANNEL <= 7);

    reg [PERIOD_WIDTH-1:0] clocks_to_soc;
    reg [WAIT_WIDTH-1:0] wait_clocks;
    reg busy;
    reg eoc_armed;
    reg priming;
    reg pd_prepared;

    assign adc_channel = CHANNEL;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            adc_soc <= 1'b0;
            adc_pd <= 1'b1;
            sample_valid <= 1'b0;
            sample_data <= 12'd0;
            fault <= 1'b0;
            clocks_to_soc <= 5;
            wait_clocks <= 0;
            busy <= 1'b0;
            eoc_armed <= 1'b0;
            priming <= 1'b1;
            pd_prepared <= 1'b0;
        end else if (!CONFIG_VALID) begin
            // An invalid static configuration is a persistent fault.
            adc_soc <= 1'b0;
            adc_pd <= 1'b1;
            sample_valid <= 1'b0;
            sample_data <= 12'd0;
            fault <= 1'b1;
            clocks_to_soc <= 5;
            wait_clocks <= 0;
            busy <= 1'b0;
            eoc_armed <= 1'b0;
            priming <= 1'b1;
            pd_prepared <= 1'b0;
        end else begin
            adc_soc <= 1'b0;
            adc_pd <= 1'b0;
            sample_valid <= 1'b0;
            fault <= 1'b0;

            if (busy && adc_eoc && eoc_armed) begin
                sample_data <= adc_dout;
                sample_valid <= 1'b1;
                busy <= 1'b0;
                wait_clocks <= 0;
            end else if (busy) begin
                if (!adc_eoc)
                    eoc_armed <= 1'b1;
                wait_clocks <= wait_clocks + 1'b1;
            end

            if (busy && !(adc_eoc && eoc_armed) &&
                (wait_clocks == TIMEOUT_CYCLES - 1)) begin
                // PD cancels the old physical conversion, so its late EOC
                // cannot be mistaken for the new request. Retry after 5 clocks.
                adc_pd <= 1'b1;
                fault <= 1'b1;
                busy <= 1'b0;
                eoc_armed <= 1'b0;
                wait_clocks <= 0;
                clocks_to_soc <= 4;
                priming <= 1'b1;
                pd_prepared <= 1'b1;
            end else if (clocks_to_soc == 0) begin
                clocks_to_soc <= PERIOD_CYCLES - 1;
                priming <= 1'b0;
                pd_prepared <= 1'b0;
                // Skip a scheduled slot if the preceding request still waits.
                // EOC and a new request may share this controller clock edge.
                if ((!busy || (adc_eoc && eoc_armed)) &&
                    (!SPARSE || pd_prepared)) begin
                    adc_soc <= 1'b1;
                    busy <= 1'b1;
                    eoc_armed <= !adc_eoc;
                    wait_clocks <= 0;
                end
            end else begin
                clocks_to_soc <= clocks_to_soc - 1'b1;
                if ((clocks_to_soc == 5) && (SPARSE || priming) &&
                    (!busy || (adc_eoc && eoc_armed))) begin
                    adc_pd <= 1'b1;
                    pd_prepared <= 1'b1;
                end
            end
        end
    end
endmodule
