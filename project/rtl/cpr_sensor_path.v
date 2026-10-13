// cpr_sensor_path —— ADC 采样链顶层（纯 RTL，不含 ADC 原语）
//
// 四级流水，只有第 ② 级跨时钟域：
//
//   adc_clk 域 (12.295 MHz)                    app_clk 域 (25 MHz)
//   ─────────────────────────                  ─────────────────────
//   ① adc_ctrl        请求转换 + 收结果
//        │ sample_valid / sample_data / fault(脉冲)
//        ▼
//   ② sample_mailbox  12 位整体跨域 ═══════════▶ raw_valid / raw_data
//        │ overflow_sticky                        │
//        │                                        ▼
//        │                              ③ pressure_normalize
//        │                                 3000-adc → 压力码 + 4 点均值
//        │                                        │ pressure_valid / pressure_data
//        │                                        ▼
//        │                              ④ peak_detect
//        │                                 滞回 100/150 + 记录峰值 + 完整释放才完成
//        │                                        │ peak_valid(1拍) / peak_value / depth_grade
//        ▼                                        ▼
//   粘滞故障汇聚 ────────────────────────▶ peak_event / sensor_fault
//
// 参数说明：
//   ADC_CLK_HZ  必须等于真实的 adc_clk 频率，采样间隔由它算出来
//   SAMPLE_HZ   期望采样率；实际间隔 = round(ADC_CLK_HZ/SAMPLE_HZ) 个时钟
//               本工程 12295082/200000 → 61 个时钟 → 实际 201558.72 Sa/s
//   TIMEOUT_CYCLES 单次转换等待上限，超时则拉 PD 取消并重试
//   RELEASE_BASELINE / TRIGGER_LEVEL / RELEASE_LEVEL / TARGET_LOW / TARGET_HIGH
//               均为【未标定的压力码】，不是毫米/厘米
//
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

    // 【第 ① 级】ADC 请求控制器（纯 RTL，不含 ADC 原语）
    //   产生 soc 脉冲请求转换，等 eoc 取回 12 位结果；
    //   超时则拉 pd 取消旧转换并在 5 拍后重试；fault 是【脉冲】
    adc_ctrl #(
        .ADC_CLK_HZ     (ADC_CLK_HZ),
        .SAMPLE_HZ      (SAMPLE_HZ),
        .CHANNEL        (CHANNEL),
        .TIMEOUT_CYCLES (TIMEOUT_CYCLES)
    ) u_adc (
        .clk          (adc_clk),
        .rst_n        (adc_rst_n),
        .adc_eoc      (adc_eoc),
        .adc_dout     (adc_dout),
        .adc_soc      (adc_soc),
        .adc_pd       (adc_pd),
        .adc_channel  (adc_channel),
        .sample_valid (adc_sample_valid),
        .sample_data  (adc_sample_data),
        .fault        (adc_fault)
    );

    // 【第 ② 级】12 位整体跨时钟域（adc_clk → app_clk）★唯一跨域点
    //   toggle 握手 + 数据保持，保证 dst 采样期间 src_hold 不变；
    //   src_busy 期间若再来样本则丢弃并置 overflow_sticky（粘滞，需共同复位）
    sample_mailbox u_mailbox (
        .src_clk         (adc_clk),
        .src_rst_n       (adc_rst_n),
        .src_valid       (adc_sample_valid),
        .src_data        (adc_sample_data),
        .src_busy        (mailbox_busy),
        .overflow_sticky (overflow_sticky),
        .dst_clk         (app_clk),
        .dst_rst_n       (app_rst_n),
        .dst_valid       (raw_valid),
        .dst_data        (raw_data)
    );

    // 【故障汇聚 1/2】把 ADC 域的一拍 fault 脉冲锁存成【只升不降的电平】
    always @(posedge adc_clk or negedge adc_rst_n) begin
        if (!adc_rst_n)
            adc_fault_sticky <= 1'b0;
        else if (adc_fault)
            adc_fault_sticky <= 1'b1;
    end

    // 【故障汇聚 2/2】跨到 app 域。这里可以只用两级同步器（不必 toggle 握手），
    // 因为过域的是【只升不降的粘滞电平】，最多晚几拍被看到，绝不会漏掉。
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
    assign sensor_fault = fault_sync;   // ⚠️ 只有共同复位能清除，clear_session 无效

    // 【第 ③ 级】压力归一化（app_clk 域）
    //   max(RELEASE_BASELINE - adc_data, 0) 得到非负压力码；无符号饱和，不出负值
    //   FILTER_SHIFT=2 走 4 点滑动均值（前 4 个有效样本为预热期，之后才有输出）
    //   FILTER_SHIFT 只允许 0 或 2，其它值故意让 elaboration 失败
    pressure_normalize #(
        .RELEASE_BASELINE(RELEASE_BASELINE),
        .FALLING_WITH_FORCE (FALLING_WITH_FORCE),
        .FILTER_SHIFT       (FILTER_SHIFT)
    ) u_normalize (
        .clk            (app_clk),
        .rst_n          (app_rst_n),
        .adc_valid      (raw_valid),
        .adc_data       (raw_data),
        .pressure_valid (pressure_valid),
        .pressure_data(pressure_data)
    );

    // 【第 ④ 级】峰值检测（app_clk 域）
    //   滞回：>=TRIGGER_LEVEL 起按，<=RELEASE_LEVEL 才算完全松开（中间回落不算结束）
    //   只有"完整松开"那一拍才产生 peak_valid（1 拍），并给出峰值/等级
    //   ⚠️ 故障时同时关掉它并清它的状态（两道闸门）：
    //        enabled       && !sensor_fault
    //        clear_session ||  sensor_fault
    peak_detect #(
        .TRIGGER_LEVEL (TRIGGER_LEVEL),
        .RELEASE_LEVEL (RELEASE_LEVEL),
        .TARGET_LOW    (TARGET_LOW),
        .TARGET_HIGH   (TARGET_HIGH)
    ) u_peak (
        .clk   (app_clk),
        .rst_n (app_rst_n),
        .enabled(enabled && !sensor_fault),
        .clear_session(clear_session || sensor_fault),
        .sample_valid (pressure_valid),
        .sample_data  (pressure_data),
        .peak_valid   (detector_event),
        .peak_value   (peak_value),
        .depth_grade  (peak_grade),
        .in_press     ()          // 有意不导出；将来要"持压指示"再开接口
    );

    // 【故障闸门 3/3】再堵一次输出：故障在某个 app 时钟沿刚同步完成的那一拍，
    // peak_detect 可能恰好同拍产生事件（enabled 要到下一拍才通过组合逻辑关它），
    // 这一行把那个漏网事件也挡掉。
    // Also gate the external event on the cycle fault synchronization completes.
    assign peak_event = detector_event && !sensor_fault;
endmodule
