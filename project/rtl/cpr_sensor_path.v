// Pure RTL ADC -> coherent CDC -> pressure filter -> release-completed event.
// The board top owns the EG_PHY_ADC primitive, its clock, channel/pad and VREF.
module cpr_sensor_path #(
    parameter integer ADC_CLK_HZ = 12295082,
    parameter integer SAMPLE_HZ = 200000,
    parameter integer CHANNEL = 1,
    parameter integer TIMEOUT_CYCLES = 64,
    parameter [11:0] RELEASE_BASELINE = 12'd3000,
    parameter integer FALLING_WITH_FORCE = 1,
    parameter integer FILTER_SHIFT = 2,
    parameter [11:0] TRIGGER_LEVEL = 12'd150,
    parameter [11:0] RELEASE_LEVEL = 12'd100,
    parameter [11:0] TARGET_LOW = 12'd800,
    parameter [11:0] TARGET_HIGH = 12'd1600
) (
    input  wire        adc_clk,
    input  wire        adc_rst_n,
    input  wire        app_clk,
    input  wire        app_rst_n,
    input  wire        adc_eoc,
    input  wire [11:0] adc_dout,
    output wire        adc_soc,
    output wire        adc_pd,
    output wire [2:0]  adc_channel,
    input  wire        enabled,
    input  wire        clear_session,
    output wire        peak_event,
    output wire [1:0]  peak_grade,
    output wire [11:0] peak_value,
    output wire        raw_valid,
    output wire [11:0] raw_data,
    output wire        sensor_fault
);
    wire adc_sample_valid;
    wire [11:0] adc_sample_data;
    wire adc_fault;
    wire mailbox_busy;
    wire overflow_sticky;
    wire pressure_valid;
    wire [11:0] pressure_data;
    wire detector_event;
    reg adc_fault_sticky;
    reg fault_meta;
    reg fault_sync;

    adc_ctrl #(
        .ADC_CLK_HZ(ADC_CLK_HZ), .SAMPLE_HZ(SAMPLE_HZ),
        .CHANNEL(CHANNEL), .TIMEOUT_CYCLES(TIMEOUT_CYCLES)
    ) u_adc (
        .clk(adc_clk), .rst_n(adc_rst_n), .adc_eoc(adc_eoc),
        .adc_dout(adc_dout), .adc_soc(adc_soc), .adc_pd(adc_pd),
        .adc_channel(adc_channel), .sample_valid(adc_sample_valid),
        .sample_data(adc_sample_data), .fault(adc_fault)
    );

    sample_mailbox u_mailbox (
        .src_clk(adc_clk), .src_rst_n(adc_rst_n),
        .src_valid(adc_sample_valid), .src_data(adc_sample_data),
        .src_busy(mailbox_busy), .overflow_sticky(overflow_sticky),
        .dst_clk(app_clk), .dst_rst_n(app_rst_n),
        .dst_valid(raw_valid), .dst_data(raw_data)
    );

    always @(posedge adc_clk or negedge adc_rst_n) begin
        if (!adc_rst_n)
            adc_fault_sticky <= 1'b0;
        else if (adc_fault)
            adc_fault_sticky <= 1'b1;
    end

    // Both inputs are sticky source-domain levels. No event pulse crosses here.
    always @(posedge app_clk or negedge app_rst_n) begin
        if (!app_rst_n) begin
            fault_meta <= 1'b0;
            fault_sync <= 1'b0;
        end else begin
            fault_meta <= adc_fault_sticky || overflow_sticky;
            fault_sync <= fault_meta;
        end
    end
    assign sensor_fault = fault_sync;

    pressure_normalize #(
        .RELEASE_BASELINE(RELEASE_BASELINE),
        .FALLING_WITH_FORCE(FALLING_WITH_FORCE), .FILTER_SHIFT(FILTER_SHIFT)
    ) u_normalize (
        .clk(app_clk), .rst_n(app_rst_n), .adc_valid(raw_valid),
        .adc_data(raw_data), .pressure_valid(pressure_valid),
        .pressure_data(pressure_data)
    );

    peak_detect #(
        .TRIGGER_LEVEL(TRIGGER_LEVEL), .RELEASE_LEVEL(RELEASE_LEVEL),
        .TARGET_LOW(TARGET_LOW), .TARGET_HIGH(TARGET_HIGH)
    ) u_peak (
        .clk(app_clk), .rst_n(app_rst_n),
        .enabled(enabled && !sensor_fault),
        .clear_session(clear_session || sensor_fault),
        .sample_valid(pressure_valid), .sample_data(pressure_data),
        .peak_valid(detector_event), .peak_value(peak_value),
        .depth_grade(peak_grade), .in_press()
    );

    // Also gate the external event on the cycle fault synchronization completes.
    assign peak_event = detector_event && !sensor_fault;
endmodule
