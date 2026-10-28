// adc_ctrl —— ADC 请求 / 完成控制器（纯 RTL，本模块内不含 ADC 原语）
//
// 采样率是怎么来的（本工程实际值）：
//   REQUEST_CYCLES = (ADC_CLK_HZ + SAMPLE_HZ/2) / SAMPLE_HZ   ← 就近取整
//                  = (12295082 + 100000) / 200000 = 61 个 ADC 时钟
//   实际采样率     = 12295082 / 61 = 201558.72 Sa/s   ← 不是 200000！
//   误差 +0.78%，因为分频只能取整数。契约要求【报告实际值，不得标称 200 kHz】。
//
// 三个关键机制：
//   ① EOC 新鲜度锁：必须看到 eoc 先低后高才认，防上一次的残留 EOC 被误判
//   ② 超时保护：64 个时钟没等到 eoc → 拉 pd 取消旧转换 → 5 拍后重试
//   ③ 槽位跳过：上一次还没完成就不发 SOC，保证最小间隔不被压缩
//
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
    // 本工程：(12295082 + 200000/2) / 200000 = 61 个时钟 → 实际 201558.72 Sa/s
    localparam integer REQUEST_CYCLES = (SAMPLE_HZ > 0) ?
        ((ADC_CLK_HZ + SAMPLE_HZ / 2) / SAMPLE_HZ) : 6;
    localparam integer PERIOD_CYCLES = (REQUEST_CYCLES >= 6) ?
        REQUEST_CYCLES : 6;
    localparam integer PERIOD_WIDTH = count_width(PERIOD_CYCLES);
    localparam integer WAIT_WIDTH = count_width(TIMEOUT_CYCLES + 1);
    // ceil(10 us * ADC_CLK_HZ), avoiding a large run-time multiplication.
    // 周期 >= 10us 时进入"稀疏采样"：每个周期都要在 SOC 前 5 拍重新拉 PD 唤醒。
    // 本工程 61 < 123，所以 SPARSE=0（稠密模式），稳态 adc_pd 恒为 0。
    localparam integer SPARSE_LIMIT = (ADC_CLK_HZ + 99999) / 100000;
    localparam integer SPARSE = PERIOD_CYCLES >= SPARSE_LIMIT;
    // This registered controller needs 18 clocks to receive a 16-clock model
    // result. The primitive's published 1 MS/s maximum is not this wrapper's
    // guaranteed throughput at every clock frequency.
    // CONFIG_VALID 是【编译期常量】：参数非法时整个控制器静态停机
    // （soc=0 / pd=1 / fault 恒高），属于持久故障而不是脉冲。
    localparam integer CONFIG_VALID =
        (ADC_CLK_HZ > 0) && (ADC_CLK_HZ <= 16000000) &&
        (SAMPLE_HZ > 0) && (SAMPLE_HZ <= 1000000) &&
        (REQUEST_CYCLES >= 18) && (!SPARSE || REQUEST_CYCLES >= 23) &&
        (TIMEOUT_CYCLES >= 18) &&
        (CHANNEL >= 0) && (CHANNEL <= 7);

    reg [PERIOD_WIDTH-1:0] clocks_to_soc;
    reg [WAIT_WIDTH-1:0] wait_clocks;
    reg busy;
    reg eoc_d;          // EOC 打一拍，用来取上升沿
    reg eoc_armed;      // 旧实现的保鲜锁，现在只保留复位/发 SOC 时的清零
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
            eoc_d <= 1'b0;
            eoc_armed <= 1'b0;
            priming <= 1'b1;
            pd_prepared <= 1'b0;
        end else begin
            eoc_d <= adc_eoc;
            adc_soc <= 1'b0;
            adc_pd <= 1'b0;
            sample_valid <= 1'b0;
            fault <= 1'b0;

            // ── 机制①：EOC 新鲜度锁 ────────────────────────────────────
            // 接受条件三个都要：busy（本次请求在途）&& eoc（转换结束）
            //                    && eoc_armed（已确认见过 eoc 低电平）
            // eoc_armed 的作用：SOC 发出那一瞬间若 eoc 已经为高（上一次的残留），
            // arm 会置 0；必须先看到 eoc 变低才解锁，从而杜绝把旧结果当新结果。
            // 2026-10-28：原来要求"先见到 EOC 低电平才允许认下一次高"，一旦 ADC 把
            // EOC 保持为高（或脉宽横跨 SOC），eoc_armed 永远打不开 → 只捕获第一拍，
            // 之后每次超时（板上实测 raw_data 冻结在 3888）。改成认上升沿：旧结果
            // 的高电平在 SOC 之前就已经产生过上升沿，不会重复计。
            if (busy && adc_eoc && !eoc_d) begin
                sample_data <= adc_dout;      // 12 位结果与 valid 同拍寄存
                sample_valid <= 1'b1;         // ← 一拍脉冲
                busy <= 1'b0;
                wait_clocks <= 0;
            end else if (busy) begin
                wait_clocks <= wait_clocks + 1'b1;
            end

            // ── 机制②：超时保护 ────────────────────────────────────────
            // wait_clocks 数到 TIMEOUT_CYCLES-1（即第 64 个忙拍 ≈ 5.2us）仍没结果：
            //   拉 pd —— 取消正在进行的物理转换，让它迟到的 EOC 无法污染下一次请求
            //   发一拍 fault 脉冲，5 拍后（clocks_to_soc<=4）重新发起
            if (busy && !(adc_eoc && !eoc_d) &&
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
            // ── 机制③：槽位跳过 ────────────────────────────────────────
            // 到点该发下一次 SOC 了。若上一次仍未完成且本拍没有可用 EOC，
            // 就【不发】SOC，只重启周期计数 —— 保证 SOC 最小间隔不被压缩。
            end else if (clocks_to_soc == 0) begin
                clocks_to_soc <= PERIOD_CYCLES - 1;
                priming <= 1'b0;
                pd_prepared <= 1'b0;
                // Skip a scheduled slot if the preceding request still waits.
                // EOC and a new request may share this controller clock edge.
                if ((!busy || (adc_eoc && eoc_armed)) &&
                    (!SPARSE || pd_prepared)) begin
                    adc_soc <= 1'b1;              // ← 一拍脉冲
                    busy <= 1'b1;
                    eoc_armed <= 1'b0;            // 上升沿检测后不再需要
                    wait_clocks <= 0;
                end
            end else begin
                clocks_to_soc <= clocks_to_soc - 1'b1;
                // 稀疏模式/前导期：在 SOC 前 5 拍拉 PD 唤醒（上升沿比 SOC 提前 5 拍）
                if ((clocks_to_soc == 5) && (SPARSE || priming) &&
                    (!busy || (adc_eoc && eoc_armed))) begin
                    adc_pd <= 1'b1;
                    pd_prepared <= 1'b1;
                end
            end
        end
    end
endmodule
