# SD / HDMI 接口时序预算

本次交付包含离线预算模型、可复现的布线后 I/O 延迟抽取、SPI 传输节拍修正及自检。**离线分析完成不等于板级 I/O 签核**：当前卡只确定为朗科 16 GB，具体系列、电气负载、PCB 延迟、DDC 波形和 HDMI 眼图仍没有实测数据。工具和记录始终保留 `physical_signoff=false`，不把参考手册的数值冒充这张卡的保证值。

## 时钟与本次修改

| 接口 | 当前实现 | 本次处理 |
|---|---|---|
| FPGA SD 逻辑 | 100 MHz | 保持原设置 |
| SPI 初始化 | DIV=248，200 kHz，半周期 2500 ns | 保持原设置 |
| SPI 正常传输 | DIV=1，约 16.667 MHz，半周期 30 ns | 由 DIV=0 / 25 MHz 改为 DIV=1 |
| 视频像素 / HDMI 串行 | 25 / 125 MHz，串行 DDR | 保持相关时钟分析，UI=4 ns |
| SDRAM | 40 MHz / 180°，已有写间隔保护 | 本轮没有修改 |

SPI 主机 CPOL=1、CPHA=1，在下降沿发出数据、下一个上升沿对应的系统时钟拍采集 MISO。RTL 的半周期为 `(DIV+2)/100 MHz`，不能误写成 `(DIV+1)`。初始化和正常传输分别建模。

原来 25 MHz 的 20 ns 半周期不能全部分配给 SD 卡：FPGA 时钟到 SCK 引脚、MISO 引脚到寄存器、时钟偏斜、setup 与不确定性都要扣除。在同步最新主分支后的一次实际路由抽取中，按参考卡 tCO=14 ns 计算，25 MHz 的剩余预算为负。因此增加一个系统时钟拍，将正常传输半周期改为 30 ns。卡端需要处理的协议没有改变；首次读卡较慢，四槽缓存完成后的翻页不增加读卡等待。

`SPI_HIGH_SPEED_DIV` 是沿用的 RTL 参数名，此处表示控制器初始化后的传输档位，**没有发送 CMD6 切换到 SD High Speed 模式**。

## SD 返回路径预算

资料包的 `4_芯片手册/SD Card/SDSDv17.pdf` 第 36–37 页给出单卡、CL≤25 pF 条件下的数据输入 setup/hold 各 5 ns、传输 tCO≤14 ns、初始化 tCO≤50 ns。这是 SanDisk 特定产品的参考电气合同，不能代替朗科具体系列的数据表。朗科公开容量/速度等级资料也没有给出当前卡的 SPI tCO，不能把 U1/C10 或连续读速换算成纳秒时序。

对实际布线报告中的物理路径进行预算，使用以下符号（单位 ns）：

- `H`：SPI 半周期，初始化 2500，传输 30；旧档位 20 用作对照。
- `Lout`：SCK 输出寄存器的时钟到达时间，相对其名义时钟沿。
- `Dout`：该寄存器时钟沿到 SCK FPGA 引脚的最大数据路径延迟。
- `Lin`：MISO 捕获寄存器的时钟到达时间，相对其名义捕获沿。
- `Din`：MISO FPGA 引脚到捕获寄存器的数据路径延迟。
- `Tsu`、`U`：捕获 setup 与时钟不确定性。

返回路径允许的外部总延迟为：

```text
tCO_card + tPCB_clock + tPCB_MISO
    <= H + Lin_min - Lout_max - Dout_max - Din_max - Tsu_max - U
```

预算器不使用 CRPR 的正向抵消信用；报告中的时钟到达值已经减去名义边沿，避免把 10 ns/40 ns 周期算入物理延迟。先移除抽取坐标再计算 `Din/Dout`，不能直接把报告总延迟当成 FPGA 延迟。结果中的剩余 PCB 预算是**条件上限**，没有宣称 PCB 实测满足它；当前卡的 tCO 若与参考合同不同，必须重新计算。

分析虚拟时钟的报告默认 uncertainty 为零；预算仍至少保留产品真实时钟路径所使用的 **0.100 ns** 不确定性，分别记录虚拟报告值和最终预算值，避免抽取时丢失这项余量。

MOSI/CS 的卡端要求仍为 setup/hold 各 5 ns，必须相对卡端 SCK 而非 FPGA 原始 100 MHz 输入检查。SPI 自检覆盖实际产品主机的边沿、位序与 MOSI setup/hold；CS 由测试环境按事务合同驱动，不能把这项组件自检当作整机 CS 边界的实测结论。

预算器也抽取全部 SD 输出的 max/min 路径。令 `Smax/Smin` 为 SCK 的时钟到达加输出路径包络，`Mmax/Mmin` 为 MOSI 的同类包络，则连续字节内的数据预算为：

```text
PCB_MOSI - PCB_SCK <= H + Smin - Mmax - 5 - U    （setup）
PCB_SCK - PCB_MOSI <= H + Mmin - Smax - 5 - U    （hold）
```

MISO hold 按下一次下降沿最早改变数据、参考 `tCO_min=0` 建模：`H + Smin + Din_min - Lin_max - Thold - U`，这是 PCB 往返延迟取零时的条件余量。实际正的往返延迟有利于 hold，但会消耗上式 setup 预算。CS 的 FPGA 延迟包络会保存；事务首尾是否满足卡端时序仍需整机/实测核对，不以延迟包络代替协议边界检查。

## HDMI / DDC 预算

HDMI 发送端采用四个相同的序列化通道和 ODDR，10 bit/字符、25 MHz 像素、125 MHz DDR，得到 250 Mbit/s 与 4 ns UI。依据 [Analog Devices HDMI 布线指南](https://ez.analog.com/video/a/documents/c/hdmi-faq/DO9240/hdmi-layout-guideline) 中的发送端关系：

| 项目 | 关系 | 当前速率下的预算 |
|---|---|---:|
| 字符周期 | 10 × UI | 40 ns |
| 差分对内偏斜 | 0.15 × UI | 0.6 ns |
| 通道间偏斜 | 0.20 × 字符周期 | 8 ns |

布线抽取核对四个逻辑 P 输出的数字发送延迟。TD 打印的同角点通道差异不等于接插件处实测偏斜，也不能证明自动映射的 N 引脚、差分幅度、抖动、上升/下降沿或眼图满足 HDMI 电气要求。亚皮秒/皮秒打印精度下的相同值只能写成“模型中未分辨差异”。本轮不更改像素/串行时钟关系，也不设置互斥时钟来消除路径。

DDC 使用加密 IP，顶层设置 `IIC_SCL_DIV=250`。该参数不能单独证明 SCL 的实际频率或占空比。按 [NXP UM10204 Rev.7.0 表 11](https://www.nxp.com/docs/en/user-guide/UM10204.pdf) 的 Standard-mode 参考合同列出边界：SCL≤100 kHz、低电平≥4.7 μs、高电平≥4.0 μs、SDA setup≥250 ns、hold≥0 ns、上升时间≤1000 ns、下降时间≤300 ns。最终仍需测 SCL/SDA 波形并检查接收端要求。

上拉 RC 的 30%→70% 上升时间预算为 `tr≈0.8473×Rp×Cb`。预算器提供 `Rp_max=tr_max/(0.8473×Cb)`，不填写未知的实际上拉/电容。例如 Cb=100 pF 时，1000 ns 上升时间对应 Rp≤约 11.8 kΩ；这只是计算示例。

## 离线抽取与产品约束的边界

`tools/collect_io_paths.py` 在已完成布线的检查点上建立**分析专用虚拟参考时钟**，每个接口端口单独成组，使输入/输出 setup 和 hold 路径都能被报告。使用 1 ns 坐标原点及 ±0.001 ns 的最小坐标，随后从数据路径中移除。它们不是板级延迟，可能导致坐标报告出现负 slack，**不能据此判定产品失败，也不能把坐标报告当成产品验收报告**。

坐标 SDC 只写入被 Git 忽略的 `project/build/io_coordinates_*/`，不会加入产品的 `timing.sdc`、工程源清单、布局布线或 bitgen。采集只读检查点，检查采集前后哈希不变，不下载板卡。没有给 SD/HDMI 填入任意零延迟，没有添加掩盖真实数据通路的 false_path 或多周期例外。

预算 JSON 分开记录 FPGA 已抽取数值、外部参考要求和仍未测量的项目。采集进程成功只表示离线采集完整；机器字段 `physical_signoff=false` 不会自动变成 true。

完整性门禁要求 MISO 及七个 SD/HDMI 输出均有 setup/hold 路径，缺任一 min/max 路径即返回 `incomplete`。HDMI 输出保存每个包络所报告的 slow/fast 标签，不将最大路径之间的相同打印值当成模拟或全角点偏斜结论。

## 验证与复现

新增实际 RTL 自检：

- `tb_spi_io_timing`：200 kHz 初始化、旧 25 MHz 对照、新 16.667 MHz 档位；卡输出延迟和 MOSI 位序/建立保持检查。`+LATE_MISO` 使旧 25 MHz 子用例延迟到 30 ns，必须失败。
- `tb_hdmi_lane_timing`：四个产品序列化通道的共同字符边界和多组数据位序。ODDR 简化模型按安装版 `sim_release/eg4/eg_logic_io.v` 的“双数据均在上升沿捕获，d1 在下降沿输出”语义编写。`+BAD_ODDR` 移除 d1 保留拍，必须失败。该模型不验证模拟电气特性。
- SD 命令/扇区/图片恢复及重试上限回归，检查改变 SPI 传输档位后恢复逻辑仍能通过原有自检。

完整构建以用户现有 TD 6.2.168116 运行。同步主分支后默认布局在模糊背景路径上出现 −0.040 ns setup；本次将文档支持的 placement `opt_timing` 改为 `high`，保留原来的时钟和路径要求。没有加入时序豁免。生成位流没有上板，不能借用此前 D123 位流的无白线结论。

最终输入对应 `verify_20261024T110502.993321Z`，构建期间源文件和 TD 哈希均不变；结构化数值、报告与位流哈希见[本次验证记录](io-timing-verification-20261024.json)。本次 **6 项 RTL 自检、27 项 Python 检查通过，2 项错误注入按预期失败**。不是全项目所有历史用例重新执行的总数。

| 最终结果 | top | top_adc |
|---|---:|---:|
| 内部 Setup WNS | +0.117 ns | +0.027 ns |
| 内部 Hold WNS | +0.003 ns | +0.003 ns |
| Setup / Hold TNS | 0 / 0 | 0 / 0 |
| LUT / 19600 | 11871 | 11805 |
| BRAM / 64 | 40 | 40 |
| 实际位流生成 | 是 | 是 |
| 关键告警数 | 7 | 7 |
| 严格检查状态 | failed | failed |
| SD 传输外部 tCO+PCB 总预算 | 20.864 ns | 20.902 ns |
| 扣参考 tCO=14 ns 后 PCB 往返预算 | 6.864 ns | 6.902 ns |
| 旧 25 MHz 同模型的剩余预算 | −3.136 ns | −3.098 ns |
| MOSI setup / hold 的差分 PCB 延迟预算 | 各 22.648 ns | 各 22.648 ns |
| MISO 零 PCB、tCO_min=0 的 hold 余量 | 35.107 ns | 35.075 ns |

HDMI 四路 P 逻辑输出的 slow 最大包络均为 4.404 ns、fast 最小包络均为 3.215 ns，打印精度为 0.001 ns；最大包络间的差异在模型打印精度内未分辨，不能据此宣称实测偏斜为零。全部 SD/HDMI 所需 min/max 路径均已采集，路由检查点采集前后哈希不变。

每个顶层的 7 条关键告警为 PHY-7002 三条、PHY-5079 一条、USR-6135 三条；告警家族与新构建的官方例程一致，条数随实现阶段重复诊断变化，不构成豁免。当前默认 `USE_EXTERNAL_IO=1`，新增六键面板保留不动；接口清单按这个配置重算为输入 25 项、输出 29 项（DDC SDA 双向计数，去重 53 位）。dangling 摘要为 3/4 个模型组，对应明细 500/584 个原语引脚，仍分别记录，不当成功能故障数量。

在仓库根目录复现：

```text
python tests/sim/run.py tb_spi_io_timing tb_hdmi_lane_timing --iverilog <iverilog> --vvp <vvp>
python project/verify_td.py --td <TD>/bin/td_commands_prompt.exe --tops top top_adc --stage full
python project/tools/collect_io_paths.py --td <TD>/bin/td_commands_prompt.exe --evidence project/build/verify_<本次时间> --output <新的证据目录>
python project/audit_interfaces.py --evidence project/build/verify_<本次时间> --output <新的清单.json>
```

`verify_td.py` 保留对关键告警和待审查项的严格检查，仍可能返回 failed；这不是竞赛官方判定。官方参考设计也出现的告警见[官方基线对照](official-reference-comparison-20261024.md)。接口离线工作与未完成的板级验证应分别记录，后者包括朗科卡与负载条件、DDC 波形、HDMI 电气质量及最终位流的实板回归。
