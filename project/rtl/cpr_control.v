// Application clock domain: video_clk (25 MHz on HX4S20C).
// raw inputs are active high; normalize pin polarity in the board top.
// Keys: [0] mode, [1] previous, [2] next / auto pause, [3] brightness,
//       [4] clear the current training session,
//       [5] subtitle on/off (panel K7, enabled after reset).
// Depth: cumulative contacts, 0000 released, 0001 shallow,
//        0011/0111 target, 1111 deep. Mechanical calibration is external.
module cpr_control #(
    parameter CLK_HZ = 25000000,
    parameter KEY_STABLE_MS = 20,
    parameter DEPTH_STABLE_MS = 3,
    parameter PAUSE_WARN_MS = 5000, // 5s
    parameter ROTATE_MS = 120000, // 2min
    parameter BEAT_MS = 545, // 节拍 545ms ≈ 110BPM
    parameter USE_PRESS_EVENTS = 0 // 顶层传 USE_ADC
)(
    input wire clk,
    input wire rst_n,
    input wire [5:0] raw_keys,
    input wire [3:0] raw_depth,
    output wire tick_ms,
    output wire [5:0] keys_level,
    output wire [3:0] depth_level,
    output reg [1:0] mode,
    output reg [1:0] brightness_level,
    output reg subtitle_on,
    output reg auto_run,
    output wire next_key_n,
    output wire prev_key_n,
    output wire auto_enable,
    output wire training_enabled,
    output wire [31:0] press_count,
    output wire [15:0] interval_ms,
    output wire rate_valid,
    output wire [1:0] rate_grade,
    output wire [1:0] depth_grade,
    output wire [15:0] pause_ms,
    output wire pause_warning,
    output wire [31:0] rotate_remaining_ms,
    output wire rotate_due,
    output wire beat_event,
    output wire compression_event,
    output wire sensor_fault,
    output wire [7:0] bpm_approx,
    output wire bpm_valid,
    input wire press_event,
    input wire [1:0] press_grade,
    input wire press_fault,
    output wire clear_session
);
    wire [5:0] keys_rise;
    wire [3:0] depth_rise_unused;
    // training_core clears on entry/exit as well as this explicit event.
    assign clear_session = keys_rise[4];
    timebase #(.CLK_HZ(CLK_HZ)) u_timebase (
        .clk     (clk),
        .rst_n   (rst_n),
        .tick_ms (tick_ms)
    );
    input_filter #(.WIDTH(6), .STABLE_MS(KEY_STABLE_MS)) u_keys (
        .clk     (clk),
        .rst_n   (rst_n),
        .tick_ms (tick_ms),
        .raw     (raw_keys),
        .level   (keys_level),
        .rise    (keys_rise)
    );
    input_filter #(.WIDTH(4), .STABLE_MS(DEPTH_STABLE_MS)) u_depth (
        .clk     (clk),
        .rst_n   (rst_n),
        .tick_ms (tick_ms),
        .raw     (raw_depth),
        .level   (depth_level),
        .rise    (depth_rise_unused)
    );
    // SD controller applies its own debounce in sd_card_clk. These levels
    // are persistent enough to cross domains; they are not 25 MHz pulses.
    assign next_key_n = !((mode == 2'd0) && keys_level[2]);
    assign prev_key_n = !((mode == 2'd0) && keys_level[1]);
    assign auto_enable = (mode == 2'd1) && auto_run;
    assign training_enabled = mode == 2'd2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode <= 2'd0;
            brightness_level <= 2'd3;
            auto_run <= 1'b1;
            subtitle_on <= 1'b1;          // 字幕默认开；K7 每按一下翻转
        end else begin
            if (keys_rise[0]) begin
                if (mode == 2'd2) mode <= 2'd0;
                else mode <= mode + 1'b1;
                // Each new entry into auto mode starts playback.
                if (mode == 2'd0) auto_run <= 1'b1;
            end else if (mode == 2'd1 && keys_rise[2]) begin
                auto_run <= !auto_run;
            end
            if (keys_rise[3]) brightness_level <= brightness_level + 1'b1;
            // 字幕开关与模式无关：教学/展播/训练三个界面共享同一条字幕带。
            if (keys_rise[5]) subtitle_on <= ~subtitle_on;
        end
    end
    training_core #(
        .PAUSE_WARN_MS    (PAUSE_WARN_MS),
        .ROTATE_MS        (ROTATE_MS),
        .BEAT_MS          (BEAT_MS),
        .USE_PRESS_EVENTS (USE_PRESS_EVENTS)
    ) u_training (
        .clk                 (clk),
        .rst_n               (rst_n),
        .tick_ms             (tick_ms),
        .enabled             (training_enabled),
        .clear_session       (clear_session),
        .depth_switches      (depth_level),
        .press_count         (press_count),
        .interval_ms         (interval_ms),
        .rate_valid          (rate_valid),
        .rate_grade          (rate_grade),
        .depth_grade         (depth_grade),
        .pause_ms            (pause_ms),
        .pause_warning       (pause_warning),
        .rotate_remaining_ms (rotate_remaining_ms),
        .rotate_due          (rotate_due),
        .beat_event          (beat_event),
        .compression_event   (compression_event),
        .sensor_fault        (sensor_fault),
        .press_event         (press_event),
        .press_grade         (press_grade),
        .press_fault         (press_fault)
    );
    rate_display_lut u_rate_display (
        .clk         (clk),
        .rst_n       (rst_n),
        .interval_ms (interval_ms),
        .rate_valid  (rate_valid),
        .bpm_approx  (bpm_approx),
        .bpm_valid   (bpm_valid)
    );
endmodule
