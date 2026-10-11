# 构建 HX4S20C 基础工程

这份说明用于从仓库源码重建基础架构。目标器件为 **EG4S20BG256**，板卡为 HX4S20C V1.0；默认顶层 `top` 用板载按键演示训练计数，`top_adc` 启用片内 ADC 压力采样。两者使用同一个 [project.al](project.al)、管脚表和构建脚本。

本地验证工具为 TD **6.2.168116（6.2.1）**。原仓库的 Linux/SP1 安装记录属于另一套环境，不能代替本次工具版本或验证证据。当前代码保留 HDMI、SD 原始扇区 BMP 和片内 SDRAM 链路；整体方案中的音乐、语音、转场、频谱、缩放、对比度与文字滚动尚未实现。

## 1. 准备源码和工具

完整检出仓库，或在已有稀疏检出中加入这些目录：

```sh
git sparse-checkout add project tests 05_lab_ex 03_技术方案
```

**`05_lab_ex` 是编译依赖。** 主工程直接引用其中的 HDMI 加密核、SD/BMP/帧缓存模块、音频测试音和生成 IP，不能只检出 `project/`。源文件映射见 [来源记录](docs/source-provenance.md)。

安装或准备：

- 安路 TD 6.2.1，包含 EG4 器件库和有效许可证。
- Python 3.9+ 和 Icarus Verilog，用于数字功能仿真。仿真器无需写入仓库。

在 TD GUI 中打开 `project/project.al` 可以查看源文件、约束和 IP 清单。GUI 默认顶层为 `top`；ADC 顶层请按下文运行 `build.tcl`，它还会加载 ADC 专用约束。命令行通过 `CPR_TOP` 选择顶层，不需要改写共享工程文件。

## 2. 先跑数字功能仿真

在仓库根目录执行：

```sh
python tests/sim/run.py --all --self-test-runner
```

Windows 上若工具不在 PATH，显式传入路径：

```powershell
python tests/sim/run.py --all --iverilog "C:/tools/iverilog/bin/iverilog.exe" --vvp "C:/tools/iverilog/bin/vvp.exe"
```

所有测试必须编译成功、在超时前正常结束、没有失败标记并输出指定的 `PASS`。空跑结束不算通过。运行器在 `tests/sim/build/<UTC 时间戳>/` 保存日志、源文件哈希和 `results.json`；测试清单、单项运行及 portable 工具用法见 [仿真说明](../tests/sim/README.md)。

## 3. 综合默认按键演示顶层

从仓库根目录进入 `project/`。Windows PowerShell 使用本机的 TD 命令行程序；以下路径对应此次验证环境：

```powershell
Set-Location project
$env:CPR_TOP = 'top'
& 'E:/bin/td_commands_prompt.exe' build.tcl
```

如果安装位置不同，替换可执行文件路径。Linux 使用已经配置运行库和许可证的 `td` 启动器：

```sh
cd project
CPR_TOP=top td build.tcl
```

成功末尾输出 `CPR_SYNTHESIS_PASS top`，报告写入 `project/build/top/rtl_area.rpt` 和 `gate_area.rpt`。脚本执行 RTL 和门级综合；它不执行布局布线、静态时序签核、位流生成或下载。

## 4. 综合 ADC 压力顶层

仍在 `project/` 目录中执行：

```powershell
$env:CPR_TOP = 'top_adc'
& 'E:/bin/td_commands_prompt.exe' build.tcl
```

Linux 对应命令：

```sh
CPR_TOP=top_adc td build.tcl
```

成功末尾输出 `CPR_SYNTHESIS_PASS top_adc`，报告写入 `project/build/top_adc/`。ADC 使用已有音频 PLL 的约 **12.295082 MHz** 输出，应用逻辑使用 **25 MHz** 视频时钟，不新增 PLL 或逻辑分频时钟。

也可以在仓库根目录一次执行两种顶层，并保存本次源码、工具和报告的哈希：

```powershell
python project/verify_td.py --td 'E:/bin/td_commands_prompt.exe'
```

运行器将证据保存在 `project/build/verify_<UTC 时间戳>/`，检查工具退出码、成功标记、资源报告、错误与严重告警，以及 ADC 邮箱约束命中的 12 位寄存器。普通告警会完整保留，不能将综合成功理解为告警已经解决。`--tops top_adc` 可只检查 ADC 顶层。

`timing.sdc` 只含两种顶层共用的时钟约束。`build.tcl` 仅在选择 `top_adc` 时加载 `constraints/adc_mailbox.sdc`，并检查完整 12 位源/目标寄存器；该文件由脚本显式加载，不在 `project.al` 的默认约束清单中。只在 GUI 中改顶层名字不能代替这一步。

`EG_PHY_ADC` 启用 CH1 和 VREF，VREF 对应 BG256 的 L11。CH1 的已核对信号路径为 **M10 → GPIOB30 → RN23（2→7）→ GPIOA_13 → J1 第 16 脚**。该复用模拟脚没有额外分配数字顶层端口。接入前仍需实测板卡参考电压、有效输入范围和码值方向；本次未验证模拟输入。

默认归一化为 `max(3000 - ADC 原始码, 0)`，四个有效样本滑动平均后检测峰值。触发阈值为 150，完全释放阈值为 100；峰值小于 800、800–1600、大于 1600 分别输出三档。**这些数值都是未标定 ADC 压力码，不能解释为厘米。** ADC 顶层的 OSD 标记为 `PRESS UNCAL`。

进入训练、清场、停用或复位后，检测器先观察完全释放，再接受新按压。一次按压必须完整释放才计数，中途回落不会重复计数。ADC 超时或采样邮箱溢出锁存硬件故障并抑制后续计数；清场不会解除故障，修正故障后需共同复位。接口细节见 [ADC 契约](docs/adc-contract.md)、[压力契约](docs/pressure-contract.md)、[整条采样链契约](docs/sensor-path-contract.md) 和 [训练计数契约](docs/training-contract.md)。

## 5. 使用默认按键演示

以下是代码定义的操作和预期行为，仍需上板验证：

| 板载输入 | 顶层信号 / 管脚 | 操作 |
|---|---|---|
| KEY1 | `rst_n` / A2 | 共同复位，清除训练状态和采样故障 |
| KEY2 | `key1` / B2 | 手动模式下一张；自动模式暂停/继续；默认 `top` 的训练模式中按下并释放模拟一次按压 |
| KEY3 | `key3` / B1 | 手动模式上一张 |
| KEY4 | `key2` / C1 | 手动浏览 → 自动展播 → 训练 → 手动浏览 |
| SW1–SW4 | `dip_sw[3:0]` | 默认 `top` 的按压接触模式；`0000` 按目标档 `0011` 演示 |

默认 `top` 的演示接触码为 `0001` 浅、`0011/0111` 目标、`1111` 深；其他非零组合报传感器状态异常。按压计数在 KEY2 释放后更新，不测量真实深度。`top_adc` 的训练计数来自采样链，KEY2 不再产生模拟按压。

`top` 参数 `USE_EXTERNAL_IO=1` 可选择五个外部低有效按键和四路接触输入，管脚见 [pin.adc](constraints/pin.adc)。外部按键顺序为 `[0]` 模式、`[1]` 上一张、`[2]` 下一张/暂停、`[3]` 亮度、`[4]` 清场。默认板载按键映射没有亮度和单独清场键；尚未实现板载组合键。`top_adc` 包装顶层未暴露此参数，若需要两者组合，应另建参数明确的包装顶层后复核管脚和工程入口。

图像链路保留例程的原始扇区扫描方式，要求 640×480、24 位无压缩、正高度 BMP；不能把普通文件复制到卡中就视为必然可读。素材准备见 [素材规范与烧卡流程](../03_技术方案/素材规范与烧卡流程.md)。本次构建和仿真不写 TF 卡，也不下载板卡。

## 验证记录

2026-10-11 本地验证：11 项产品 RTL 自检和 5 项运行器控制全部通过；两种顶层用 TD 6.2.168116 完成 RTL/门级综合，均无错误或严重告警。实际资源如下：

| 顶层 | LUT / 19600 | 寄存器 / 19600 | BRAM / 64 | PLL / 4 | ADC / 1 |
|---|---:|---:|---:|---:|---:|
| `top` | 5691（29.04%） | 4198 | 20 | 3 | 0 |
| `top_adc` | 5754（29.36%） | 4282 | 20 | 3 | 1 |

两种顶层各保留 43 条普通诊断，包括参考 SDRAM 的未驱动寄存器时钟、SD 写数据未使用和 IP 位宽告警。它们需要在后续联调中逐项处理；本次综合通过没有证明完整媒体链路正确。证据目录、约束绑定及负控记录见 [本次验证报告](docs/verification-report.md)，用户返回的接口审阅处理见 [DeepSeek 复核记录](docs/deepseek-review-resolution.md)。

数字仿真与综合的通过范围仅限所列源码和数字接口。布局布线、CDC 物理路径、SDRAM DQ 的 setup/hold、外设电气条件、模拟精度、机械标定与实板演示仍需独立验证。
