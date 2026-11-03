// 训练计数、频率评级、中断与轮换计时。
// 所有端口同步于 clk；tick_ms 是每毫秒一个周期的时钟使能。
// USE_PRESS_EVENTS=0 读取累计触点码：0000 释放、0001 轻、0011/0111 正常、1111 重。
// USE_PRESS_EVENTS=1 接收上游完整释放事件；press_event、clear_session 均须为单周期脉冲，无背压。
// 频率边界固定为 500/600 ms；调用方负责参数范围和机械/压力标定。
// beat_event、compression_event 为单周期脉冲；rotate_due 保持到复位、停用或清场。
module training_core #(
    parameter PAUSE_WARN_MS = 5000, // 中断提示阈值，ms
    parameter ROTATE_MS = 120000,   // 轮换周期，ms
    parameter BEAT_MS = 545,        // 节拍 545ms ≈ 110BPM
    parameter USE_PRESS_EVENTS = 0  // 输入模式开关
)(
    //基础设施
    input wire clk, input wire rst_n, input wire tick_ms,
    //控制
    input wire enabled, input wire clear_session,
    //输入 A：触点码（板载/外接盒）
    input wire [3:0] depth_switches,
    //输出：统计结果
    // [电平] 累计完成次数（浅/深/快/慢都算，不是"合格次数"）；饱和 0xFFFFFFFF
    output reg [31:0] press_count,
    // [电平] 相邻两次"完成"的间隔 ms；首次完成后保持 0，饱和 0xFFFF
    output reg [15:0] interval_ms,
    // [电平] interval_ms 是否有效；自第 2 次完成起为 1
    output reg rate_valid,
    // [电平] 频率 0=未知 1=慢(>600ms) 2=目标(500~600ms) 3=快(<500ms)
    //        与压力分级分别编码
    output reg [1:0] rate_grade,
    // [电平] 深度 0=未知 1=浅 2=目标 3=深；保持到下次完成（OSD 靠它持续显示）
    output reg [1:0] depth_grade,
    // [电平] 距上次完成的停顿 ms，饱和 0xFFFF
    output reg [15:0] pause_ms,
    // [组合] 停顿超阈值；带 have_previous 门控，首次按压前恒 0
    output wire pause_warning,
    // [电平] 轮换倒计时 ms，减到 0 停（不下溢）
    output reg [31:0] rotate_remaining_ms,
    // [粘滞] 轮换到期；只在 复位/停用/清场 清 0，想触发一次性动作用前须自行检边沿
    output reg rotate_due,
    // [脉冲] 节拍，每 BEAT_MS 一拍；进入训练那一拍也补发一拍
    output reg beat_event,
    // [脉冲] 完成一次按压，当前顶层未使用
    output reg compression_event,
    // [电平] 训练级故障；事件模式取 press_fault，触点模式取 cycle_fault
    //        顶层另与 cpr_sensor_path 的粘滞故障相或
    output reg sensor_fault,
    //输入 B：事件（ADC）
    input wire press_event,
    input wire [1:0] press_grade,
    input wire press_fault
);

    reg was_enabled;      // enabled 的上一拍值，用来检测"刚进入训练"（!was_enabled）
    reg in_press;         // 按压进行中
    reg have_previous;    // 是否已有过完成；决定 rate_valid 与计时器是否走
    reg switch_armed;     // 已观察到一次完整释放
    reg [1:0] peak_grade; // 本次按压的最高档
    reg cycle_fault;      // 本次按压循环内出现过非法触点组合（锁存）
    reg [15:0] elapsed_ms,// 距上次完成的间隔计时（完成时清零）
               beat_elapsed;// 节拍计数 0..BEAT_MS-1
    reg [1:0] current_depth; // 当前触点档位（组合，见下）
    reg valid_pattern;       // 当前触点组合是否合法（组合，见下）

    wire completed_press = USE_PRESS_EVENTS ? press_event :
        ((depth_switches == 0) && in_press);
    always @(*) begin
        valid_pattern = 1;
        case (depth_switches)
            4'b0000: current_depth = 0;
            4'b0001: current_depth = 1;
            4'b0011,4'b0111: current_depth = 2;
            4'b1111: current_depth = 3;
            default: begin current_depth = 0; valid_pattern = 0; end // 非法
        endcase
    end
    // 首次完整按压前不报中断告警。
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
            // 事件输出缺省清零，触发时置位一个周期。
            beat_event <= 0; compression_event <= 0;
            // 停用、进入训练或清场优先于本拍计时和输入事件，不缓存被丢弃的事件。
            if (!enabled || !was_enabled || clear_session) begin
                in_press <= 0; have_previous <= 0; peak_grade <= 0;
                switch_armed <= 0;
                cycle_fault <= 0; elapsed_ms <= 0; beat_elapsed <= 0;
                press_count <= 0; interval_ms <= 0; rate_valid <= 0;
                rate_grade <= 0; depth_grade <= 0; pause_ms <= 0;
                rotate_remaining_ms <= ROTATE_MS; rotate_due <= 0;
                sensor_fault <= 0;
                if (enabled) beat_event <= 1;   // 进入训练瞬间补一拍节拍当提示
            end else begin
                if (tick_ms) begin
                    // 首次按压后才累加间隔与中断计时，两者分别在对应完成流程中清零。
                    if (have_previous && elapsed_ms != 16'hffff)
                        elapsed_ms <= elapsed_ms + 1'b1;
                    if (have_previous && pause_ms != 16'hffff)
                        pause_ms <= pause_ms + 1'b1;
                    if (rotate_remaining_ms > 0) begin
                        rotate_remaining_ms <= rotate_remaining_ms - 1'b1;
                        // 倒计时减到零的同拍置位 rotate_due，随后保持。
                        if (rotate_remaining_ms == 1) rotate_due <= 1;
                    end
                    if (beat_elapsed == BEAT_MS-1) begin
                        beat_elapsed <= 0; beat_event <= 1;
                    end else beat_elapsed <= beat_elapsed + 1'b1;
                end
                // 事件模式下看到故障即锁存；触点模式不用这条（完成时才取 cycle_fault）
                if (USE_PRESS_EVENTS && press_fault) begin
                    sensor_fault <= 1;
                end
                // 触点模式先观察完整释放，再允许计数，避免把入场前的持续按压计入。
                // switch_armed 的新值从下一拍生效。
                if (!USE_PRESS_EVENTS && !switch_armed && depth_switches == 0)
                    switch_armed <= 1;
                // 按压期间保留达到过的最高档。
                if (!USE_PRESS_EVENTS && switch_armed && depth_switches != 0) begin
                    if (!in_press) begin
                        in_press <= 1; peak_grade <= current_depth;
                        cycle_fault <= !valid_pattern;      // 首拍就非法则记故障
                    end else begin
                        if (current_depth > peak_grade) peak_grade <= current_depth;
                        if (!valid_pattern) cycle_fault <= 1;  // 出现过非法即锁存
                    end
                end
                // 事件模式故障时丢弃该次完成，不更新计数、间隔或评级。
                if (completed_press && !(USE_PRESS_EVENTS && press_fault)) begin
                    in_press <= 0; compression_event <= 1;
                    if (press_count != 32'hffffffff) press_count <= press_count + 1'b1;
                    sensor_fault <= USE_PRESS_EVENTS ? press_fault : cycle_fault;
                    // 深度：事件模式信上游；触点模式非法组合给 0（未知），否则取峰值
                    if (USE_PRESS_EVENTS) depth_grade <= press_grade;
                    else if (cycle_fault) depth_grade <= 0;
                    else depth_grade <= peak_grade;
                    rate_valid <= have_previous;      // 第 2 次起才有效
                    if (have_previous) begin
                        // 同拍 tick_ms 计入本次间隔，再将 elapsed_ms 清零。
                        if (tick_ms && elapsed_ms != 16'hffff)
                            interval_ms <= elapsed_ms + 1'b1;
                        else interval_ms <= elapsed_ms;
                        // 评级包含同拍 tick_ms：499+tick 归目标档，600+tick 归慢档。
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
