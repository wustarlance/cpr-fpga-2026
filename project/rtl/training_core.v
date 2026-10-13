// training_core —— 训练计数 / 计时 / 评级核心
//
// 职责：判定"一次完整按压"、累计次数、测量间隔并评级、计时暂停与轮换、产生节拍。
//
// 关键约定：
//   · 所有端口同步于同一个 clk（顶层为 video_clk 25 MHz）。
//   · tick_ms 是每毫秒一拍的【时钟使能】，不是时钟，不要拿它当时钟边沿。
//   · 按压输入两条互斥路径，由 USE_PRESS_EVENTS 选择：
//       =0 触点模式：depth_switches 温度计码（板载演示 / 外接盒）
//       =1 事件模式：press_event 由 ADC 链的 peak_detect 给出
//   · 本模块【没有输入边沿检测】【没有背压】：press_event / clear_session
//     必须是一个 clk 宽的脉冲；持续拉高会逐拍重复处理。
//   · 本模块【没有参数合法性检查】，越界配置静默出错。
//   · 500/600 ms 速率边界写死在源码里，不能用参数调整。
//
// 输出信号类型速查：
//   [脉冲] 宽 1 拍：beat_event, compression_event
//   [粘滞] 只置不清（复位/停用/清场才清）：rotate_due
//   [组合] wire，随输入即时变化：pause_warning
//   [电平] 其余，保持到下次事件
//
// All ports are synchronous to clk. tick_ms must pulse once per millisecond.
// Depth switches are cumulative: 0000 released, 0001 shallow,
// 0011/0111 target band, 1111 deep. Mechanical calibration is required.
module training_core #(
    parameter PAUSE_WARN_MS = 5000, // 停顿多久算"暂停"→ 5 秒
    parameter ROTATE_MS = 120000,   // 换人提醒周期 → 2 分钟
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
    //        注意与 depth_grade 的 1/2/3 含义不同，勿混
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
    // [脉冲] 完成一次按压；当前顶层未接消费者，是给统计/上报预留的钩子
    output reg compression_event,
    // [电平] 训练级故障；事件模式取 press_fault，触点模式取 cycle_fault
    //        与 cpr_sensor_path 的硬件粘滞故障不是一回事（顶层再相或）
    output reg sensor_fault,
    //输入 B：事件（ADC）
    input wire press_event,
    input wire [1:0] press_grade,
    input wire press_fault
);
    // Grades: rate 0 unknown, 1 slow, 2 target, 3 fast;
    // depth 0 unknown, 1 shallow, 2 target, 3 deep.

    reg was_enabled;      // enabled 的上一拍值，用来检测"刚进入训练"（!was_enabled）
    reg in_press;         // 按压进行中
    reg have_previous;    // 是否已有过完成；决定 rate_valid 与计时器是否走
    reg switch_armed;     // 已武装：必须先见过一次 depth_switches==0 才置 1
    reg [1:0] peak_grade; // 本次按压到达过的【最深】档，按压中取 max
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
    // [组合] 停顿告警。三个条件缺一不可：
    //   enabled      —— 不在训练模式不报
    //   have_previous—— 首次按压前不报（否则一进训练就喊"你停顿了"）
    //   pause_ms >= PAUSE_WARN_MS
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
            // [脉冲] 每拍先清 0，只有后面的 if 命中才置 1 → 宽度恒为 1 拍
            beat_event <= 0; compression_event <= 0;
            // 【第 2 层】清场：命中后本拍的 tick_ms / 输入事件 / 故障更新全部丢弃，
            // 不排队到下一拍（契约明确要求）。!was_enabled = 使能上升沿，即刚进训练。
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
                // 【第 3 层】正常处理。以下各 if 顺序执行，后面的赋值覆盖前面的。
                if (tick_ms) begin
                    // elapsed_ms 与 pause_ms 都在数"距上次完成多久"，
                    // 区别只在清零时机；两者都受 have_previous 门控（首次按压前不走）
                    if (have_previous && elapsed_ms != 16'hffff)
                        elapsed_ms <= elapsed_ms + 1'b1;
                    if (have_previous && pause_ms != 16'hffff)
                        pause_ms <= pause_ms + 1'b1;
                    if (rotate_remaining_ms > 0) begin
                        rotate_remaining_ms <= rotate_remaining_ms - 1'b1;
                        // ★ 在 ==1 时置位（不是 ==0）：本拍置位并减到 0，
                        //   下拍 >0 不成立即停止递减，rotate_due 就此保持为 1（粘滞）
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
                // ★ 武装：必须先见过一次"完全释放"才允许开始计数。
                //   否则"进训练前就一直压着"会在松手时凭空多计一次。
                //   注意此处是 <=，本拍不生效，所以下面读到的还是旧值。
                if (!USE_PRESS_EVENTS && !switch_armed && depth_switches == 0)
                    switch_armed <= 1;
                // 【捕获】按下的过程中：首拍记录档位，之后持续取最深值
                if (!USE_PRESS_EVENTS && switch_armed && depth_switches != 0) begin
                    if (!in_press) begin
                        in_press <= 1; peak_grade <= current_depth;
                        cycle_fault <= !valid_pattern;      // 首拍就非法则记故障
                    end else begin
                        if (current_depth > peak_grade) peak_grade <= current_depth;
                        if (!valid_pattern) cycle_fault <= 1;  // 出现过非法即锁存
                    end
                end
                // 【第 4 层】完成。事件模式下 press_fault 会把整个分支抑制掉：
                //   不计次、不更新间隔/等级、不发 compression_event（"不对称"处理）
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
                        // Account for a coincident millisecond tick before resetting.
                        // 本拍若同时有 tick_ms，那 1 ms 会被下面的清零吃掉，这里补回来
                        if (tick_ms && elapsed_ms != 16'hffff)
                            interval_ms <= elapsed_ms + 1'b1;
                        else interval_ms <= elapsed_ms;
                        // ★ 边界修正：真实间隔 = elapsed_ms + (本拍是否有 tick)。
                        //   499+tick 其实是 500（目标），600+tick 其实是 601（慢），
                        //   两个额外条件就是把这两个边界从错误分类里拉回来。
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
