// All ports are synchronous to clk. tick_ms must pulse once per millisecond.
// Depth switches are cumulative: 0000 released, 0001 shallow,
// 0011/0111 target band, 1111 deep. Mechanical calibration is required.
module training_core #(
    parameter PAUSE_WARN_MS = 5000,
    parameter ROTATE_MS = 120000,
    parameter BEAT_MS = 545,
    parameter USE_PRESS_EVENTS = 0
)(
    input wire clk, input wire rst_n, input wire tick_ms,
    input wire enabled, input wire clear_session,
    input wire [3:0] depth_switches,
    output reg [31:0] press_count,
    output reg [15:0] interval_ms,
    output reg rate_valid,
    output reg [1:0] rate_grade,
    output reg [1:0] depth_grade,
    output reg [15:0] pause_ms,
    output wire pause_warning,
    output reg [31:0] rotate_remaining_ms,
    output reg rotate_due,
    output reg beat_event,
    output reg compression_event,
    output reg sensor_fault,
    input wire press_event,
    input wire [1:0] press_grade,
    input wire press_fault
);
    // Grades: rate 0 unknown, 1 slow, 2 target, 3 fast;
    // depth 0 unknown, 1 shallow, 2 target, 3 deep.
    reg was_enabled, in_press, have_previous;
    reg switch_armed;
    reg [1:0] peak_grade;
    reg cycle_fault;
    reg [15:0] elapsed_ms, beat_elapsed;
    reg [1:0] current_depth;
    reg valid_pattern;
    wire completed_press = USE_PRESS_EVENTS ? press_event :
        ((depth_switches == 0) && in_press);
    always @(*) begin
        valid_pattern = 1;
        case (depth_switches)
            4'b0000: current_depth = 0;
            4'b0001: current_depth = 1;
            4'b0011,4'b0111: current_depth = 2;
            4'b1111: current_depth = 3;
            default: begin current_depth = 0; valid_pattern = 0; end
        endcase
    end
    // Disabled before training and until the first complete press.
    assign pause_warning = enabled && have_previous && pause_ms >= PAUSE_WARN_MS;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            was_enabled <= 0; in_press <= 0; have_previous <= 0;
            switch_armed <= 0;
            peak_grade <= 0; cycle_fault <= 0; elapsed_ms <= 0;
            beat_elapsed <= 0; press_count <= 0; interval_ms <= 0;
            rate_valid <= 0; rate_grade <= 0; depth_grade <= 0;
            pause_ms <= 0; rotate_remaining_ms <= ROTATE_MS;
            rotate_due <= 0; beat_event <= 0; compression_event <= 0;
            sensor_fault <= 0;
        end else begin
            was_enabled <= enabled;
            beat_event <= 0; compression_event <= 0;
            if (!enabled || !was_enabled || clear_session) begin
                in_press <= 0; have_previous <= 0; peak_grade <= 0;
                switch_armed <= 0;
                cycle_fault <= 0; elapsed_ms <= 0; beat_elapsed <= 0;
                press_count <= 0; interval_ms <= 0; rate_valid <= 0;
                rate_grade <= 0; depth_grade <= 0; pause_ms <= 0;
                rotate_remaining_ms <= ROTATE_MS; rotate_due <= 0;
                sensor_fault <= 0;
                if (enabled) beat_event <= 1;
            end else begin
                if (tick_ms) begin
                    if (have_previous && elapsed_ms != 16'hffff)
                        elapsed_ms <= elapsed_ms + 1'b1;
                    if (have_previous && pause_ms != 16'hffff)
                        pause_ms <= pause_ms + 1'b1;
                    if (rotate_remaining_ms > 0) begin
                        rotate_remaining_ms <= rotate_remaining_ms - 1'b1;
                        if (rotate_remaining_ms == 1) rotate_due <= 1;
                    end
                    if (beat_elapsed == BEAT_MS-1) begin
                        beat_elapsed <= 0; beat_event <= 1;
                    end else beat_elapsed <= beat_elapsed + 1'b1;
                end
                if (USE_PRESS_EVENTS && press_fault) begin
                    sensor_fault <= 1;
                end
                if (!USE_PRESS_EVENTS && !switch_armed && depth_switches == 0)
                    switch_armed <= 1;
                if (!USE_PRESS_EVENTS && switch_armed && depth_switches != 0) begin
                    if (!in_press) begin
                        in_press <= 1; peak_grade <= current_depth;
                        cycle_fault <= !valid_pattern;
                    end else begin
                        if (current_depth > peak_grade) peak_grade <= current_depth;
                        if (!valid_pattern) cycle_fault <= 1;
                    end
                end
                if (completed_press && !(USE_PRESS_EVENTS && press_fault)) begin
                    in_press <= 0; compression_event <= 1;
                    if (press_count != 32'hffffffff) press_count <= press_count + 1'b1;
                    sensor_fault <= USE_PRESS_EVENTS ? press_fault : cycle_fault;
                    if (USE_PRESS_EVENTS) depth_grade <= press_grade;
                    else if (cycle_fault) depth_grade <= 0;
                    else depth_grade <= peak_grade;
                    rate_valid <= have_previous;
                    if (have_previous) begin
                        // Account for a coincident millisecond tick before resetting.
                        if (tick_ms && elapsed_ms != 16'hffff)
                            interval_ms <= elapsed_ms + 1'b1;
                        else interval_ms <= elapsed_ms;
                        if (elapsed_ms < 500 && !(tick_ms && elapsed_ms == 499))
                            rate_grade <= 3;
                        else if (elapsed_ms > 600 || (tick_ms && elapsed_ms == 600))
                            rate_grade <= 1;
                        else rate_grade <= 2;
                    end
                    have_previous <= 1; elapsed_ms <= 0; pause_ms <= 0;
                end
            end
        end
    end
endmodule
