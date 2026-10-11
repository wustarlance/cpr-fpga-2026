# 训练计数核心接口（training_core）

`rtl/training_core.v` 是训练计数/计时核心，合成 Verilog-2001。它接收按压完成（温度计码或事件两种模式之一），累计按压次数、测量按压间隔并评级、计时暂停/轮换、产生节拍，并汇总训练级传感器故障。所有端口属于同一 `clk` 域，`tick_ms` 是每毫秒一拍的时钟使能，不是生成时钟。

## 时钟与复位

`clk` 是处理时钟；顶层实际用 25 MHz 视频时钟。`tick_ms` 必须每毫秒脉冲一拍，由 [timebase](../rtl/timebase.v) 产生：`DIV = CLK_HZ/1000`，计数器等于 `DIV-1` 时输出一拍 `tick_ms`。`timebase` 单独实例的参数默认值是 50 MHz；本工程的 `cpr_control` 显式传入 25 MHz，得到每 25000 个处理时钟一次的使能，名义周期为 1 ms。整数除法直接舍弃余数，没有余数补偿；非整除配置须报告实际周期，物理精度还取决于实际时钟。

`rst_n` 异步拉低清除全部状态；释放应由所属时钟域复位同步器完成。毫秒计时和周期节拍由 `tick_ms` 推进；按压状态、完成计数和清场在每个处理时钟检查，不要求同拍出现 `tick_ms`。`tick_ms` 停摆会冻结计时，但不会阻止有效完成事件计数。

## 端口

| 端口 | 方向 | 位宽 | 含义 |
|---|---|---:|---|
| clk | in | 1 | 处理时钟 |
| rst_n | in | 1 | 异步低有效复位 |
| tick_ms | in | 1 | 每毫秒一拍时钟使能脉冲 |
| enabled | in | 1 | 训练使能；`!enabled` 清状态 |
| clear_session | in | 1 | 清场；清按压/计数/暂停/轮换状态 |
| depth_switches | in | 4 | 累计温度计码（仅 `USE_PRESS_EVENTS=0`） |
| press_event | in | 1 | 按压完成事件（仅 `=1`） |
| press_grade | in | 2 | 按压分级（仅 `=1`） |
| press_fault | in | 1 | 按压故障（仅 `=1`） |
| press_count | out | 32 | 累计按压次数，饱和 `0xFFFFFFFF` |
| interval_ms | out | 16 | 相邻两次按压间隔 ms，饱和 `0xFFFF` |
| rate_valid | out | 1 | 间隔有效（`have_previous`），首次按压后为 0 |
| rate_grade | out | 2 | 1 慢 / 2 目标 / 3 快 |
| depth_grade | out | 2 | 0 未知 / 1 浅 / 2 目标 / 3 深 |
| pause_ms | out | 16 | 距上次按压的暂停时间 ms，饱和 `0xFFFF` |
| pause_warning | out | 1 | 组合：`enabled && have_previous && pause_ms >= PAUSE_WARN_MS` |
| rotate_remaining_ms | out | 32 | 轮换剩余时间 ms，倒计数到 0 |
| rotate_due | out | 1 | 轮换到期**电平**，粘滞到复位/停用/清场 |
| beat_event | out | 1 | 节拍一拍脉冲，每 `BEAT_MS` ms 一次 |
| compression_event | out | 1 | 按压完成一拍脉冲 |
| sensor_fault | out | 1 | 训练级传感器故障（`cycle_fault` 或 `press_fault`） |

`press_event` 和 `clear_session` 的发送方须提供一个处理时钟宽的脉冲；事件模式下，`press_grade` 与 `press_fault` 须在接收该事件的同一上升沿稳定。本模块没有边沿检测或背压：持续拉高 `press_event` 会每拍计数，持续拉高 `clear_session` 会连续清场并使 `beat_event` 保持高。按上述输入约定使用时，`beat_event`、`compression_event` 为单时钟脉冲；连续事件也可能使有效输出相邻为高，接收方应逐拍采样。

`rotate_due` 置 1 后保持到复位/停用/清场，需作为电平读取或自行检测边沿。`pause_warning` 是组合输出，训练开始前和首次按压前为 0。`rate_valid` 反映最近一次完成按压的间隔是否有效，自第二次按压起为 1，并保持到复位/停用/清场。

## 参数

| 参数 | 默认值 | 单位 | 含义 |
|---|---:|---|---|
| `PAUSE_WARN_MS` | 5000 | ms | 暂停告警阈值 |
| `ROTATE_MS` | 120000 | ms | 轮换周期 |
| `BEAT_MS` | 545 | ms | 节拍周期 |
| `USE_PRESS_EVENTS` | 0 | — | 0：温度计码输入；1：事件输入 |

这些默认值均为逻辑联调值。配置方须保证参数为整数：`PAUSE_WARN_MS` 为 0–65535，`ROTATE_MS` 为 0–4294967295，`BEAT_MS` 为 1–65536，`USE_PRESS_EVENTS` 为 0 或 1。这些界限来自 16 位暂停/节拍计数器和 32 位轮换计数器，不是已覆盖全部取值的测试声明。暂停阈值为 0 时首次完成后立即告警；轮换周期为 0 时剩余时间一直为 0，也不会产生由 1 减到 0 的到期置位。

源码没有参数合法性检查或非法配置故障输出。超出这些范围的配置不受接口契约支持，例如超过 16 位范围的节拍比较值可能永远匹配不到。参数合法性由实例化方保证；速率分级的 500/600 ms 边界在源码中固定，不能用上述参数调整。

## 两种按压输入模式

### `USE_PRESS_EVENTS=0`（默认，温度计码模式）

`completed_press = (depth_switches == 0) && in_press`。`depth_switches` 温度计码按组合逻辑解码（`always @(*)`）：

| depth_switches | current_depth | 含义 |
|---|---:|---|
| `0000` | 0 | 完全释放 |
| `0001` | 1 | 浅 |
| `0011` / `0111` | 2 | 目标带 |
| `1111` | 3 | 深 |
| 其他 | 0（`valid_pattern=0`） | 非法组合 |

状态机：先观察到 `depth_switches==0` 才武装（`switch_armed=1`）；随后 `!=0` 进入按压（`in_press=1`，`peak_grade` 取当前档，`cycle_fault=!valid_pattern`）；按压中追踪最大 `current_depth` 到 `peak_grade`，遇非法组合置 `cycle_fault=1`；回到 `0000` 完成一次按压。完成时 `depth_grade` 取 `peak_grade`，非法组合（`cycle_fault`）时取 0；`sensor_fault <= cycle_fault`。输入应已去抖并属于 `clk` 域。此模式下 `press_event`/`press_grade`/`press_fault` 不参与，实例化时应固定为 0，避免悬空输入。

### `USE_PRESS_EVENTS=1`（事件模式）

`completed_press = press_event`。正常处理分支中，`press_fault` 为高时置位 `sensor_fault`，并拒绝同拍完成事件：不加计数、不更新间隔/等级、不产生 `compression_event`。只在 `press_event && !press_fault` 时接收完成，令 `depth_grade <= press_grade`、`sensor_fault <= 0`。`depth_switches` 的组合解码仍存在但不参与事件处理（`tb_training_events` 用非法开关顺序验证了这一点）；独立实例应将未使用的输入固定为 0。事件模式不在内部重新确认释放，发送方须保证每次完整按压只产生一次事件。

## 计数与评级

完成一次按压（且未被故障抑制，见下）时，`press_count` 加 1（饱和）、`compression_event` 发一拍。

`elapsed_ms` 自上次按压后每个 `tick_ms` 加 1（`have_previous=1` 且未饱和 `0xFFFF`）。第二次及以后的完成拍，`interval_ms` 取 `elapsed_ms`；若同拍出现 `tick_ms` 且未饱和，则计入该毫秒后取值，已饱和时保持 `0xFFFF`。首次完成保持间隔/速率等级为复位值。完成后 `elapsed_ms`、`pause_ms` 清零，`rate_valid` 取更新前的 `have_previous`，即第二次按压起才有效。

`rate_grade` 由 `elapsed_ms` 及重合修正得出：

| 间隔 | rate_grade |
|---|---|
| < 500 ms | 3（快） |
| 500–600 ms | 2（目标） |
| > 600 ms | 1（慢） |

`depth_grade`：0 未知、1 浅、2 目标、3 深；复位/停用/清场后为 0。普通完成按压不重启轮换倒计时或周期节拍计数器。

## 计时与节拍

`pause_ms` 自上次按压起每个 `tick_ms` 加 1（`have_previous=1` 且未饱和），完成按压时清零。`pause_warning` 组合输出，在 `enabled && have_previous && pause_ms >= PAUSE_WARN_MS` 时为高。

`rotate_remaining_ms` 复位/停用/清场时为 `ROTATE_MS`，正常操作每个 `tick_ms` 减 1（大于 0 时）。当其等于 1 的 `tick_ms` 拍置 `rotate_due=1` 并减到 0；`rotate_due` 此后保持到复位/停用/清场。

`beat_event` 每 `BEAT_MS` ms 一拍（`beat_elapsed==BEAT_MS-1` 时清 0 并置位）；此外使能首拍（`was_enabled` 尚为 0）和使能期间 `clear_session` 的拍也各发一拍（清除分支中 `if (enabled) beat_event <= 1`）。

## 故障策略

`training_core` 的 `sensor_fault` 是训练级故障：模式 0 在完成时取 `cycle_fault`；模式 1 在正常处理分支观察到 `press_fault` 时置位，在无故障的完成事件后清零。其他普通时钟保持，复位/停用/清场时清零。它不同于 `cpr_sensor_path` 输出的硬件粘滞故障（ADC 超时/邮箱溢出，需共同复位）；顶层把两者相或后送 OSD（`sensor_fault | adc_path_fault`）。清场可以清训练级显示寄存器，但不能解除采样链的硬件故障。

故障对计数的影响不对称：温度计码模式下非法组合（`cycle_fault`）仍计一次按压，但 `depth_grade=0`、`sensor_fault=1`；事件模式下 `press_fault` 为高时完成事件被完全抑制（不计数）。这是 `completed_press && !(USE_PRESS_EVENTS && press_fault)` 门控的结果。

## 复位 / 停用 / 清场

复位清全部状态，`rotate_remaining_ms=ROTATE_MS`。`!enabled || !was_enabled || clear_session` 清按压/计数/暂停/轮换/故障状态、`rotate_remaining_ms=ROTATE_MS`、`rotate_due=0`，若 `enabled` 则置位 `beat_event`。`was_enabled` 是 `enabled` 的寄存，因此使能首拍仍走清除分支（发出首个节拍），第二拍起正常。清除分支优先于同拍的 `tick_ms`、输入事件和故障更新，这些同拍输入被丢弃，不会排队到下一拍。

## 与传感器通路的连接

`depth_switches[3:0]`（温度计码）与 `cpr_sensor_path.peak_grade[1:0]`（分级码）是两条**互斥**的输入路径，之间没有转换模块。顶层 `top` 用 `cpr_control #(.USE_PRESS_EVENTS(USE_ADC))` 选择：

- `depth_switches` 来自 `input_filter` 去抖后的 `depth_level`，源头 `raw_depth`：默认演示为 KEY2 按下输出拨码/目标档、松开回到 `0000`；`USE_EXTERNAL_IO=1` 时为外部累计接触 `~depth_sw_n`。
- `USE_ADC=0`（默认 `top`）：`press_event/grade/fault` 固定为 0，`training_core` 走温度计码模式。
- `USE_ADC=1`（`top_adc`）：`press_event=adc_peak_event`、`press_grade=adc_peak_grade`、`press_fault=adc_path_fault`（来自 `cpr_sensor_path`），走事件模式；此时 `depth_switches` 虽仍由 `raw_depth` 驱动但被忽略。

这两种输入编码由 `USE_ADC`/`USE_PRESS_EVENTS` 选择，ADC 的两位分级直接接 `press_grade`，不需要转换成四位接触码。上层接线见 [top](../rtl/top_tf_hdmi_audio.v) 与 [cpr_control](../rtl/cpr_control.v)，采样域及共同复位约定见 [整条采样链契约](sensor-path-contract.md)。

## 验证范围

`tb_training_core.v` 覆盖温度计码模式（参数 `PAUSE_WARN_MS=700`、`ROTATE_MS=2000`）；`tb_training_events.v` 覆盖事件模式（`USE_PRESS_EVENTS=1`，并用非法开关顺序验证事件模式忽略 `depth_switches`）；`tb_cpr_control.v` 覆盖 `timebase + input_filter + training_core + rate_display_lut + cpr_control` 集成。测试失败用 `$fatal(1, ...)`，成功末尾输出 `PASS`。

这些测试验证数字接口语义，不证明实际按压机械标定、传感器接触的电气条件或实板演示。`tick_ms` 的毫秒精度依赖顶层 `CLK_HZ` 配置和实际时钟。已经执行的测试与综合证据见 [基础架构验证报告](verification-report.md)，本次外部接口审阅的处理结论见 [DeepSeek 审阅复核](deepseek-review-resolution.md)。
