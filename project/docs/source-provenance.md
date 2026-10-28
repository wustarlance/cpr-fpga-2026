# 当前 PLL 来源补充（2026-10-28）

主工程的系统、视频 PLL 以及新复制到 `project/ip/PLL_HDMI_AUDIO.*` 的音频 PLL 已采用内部 VCO 自反馈。输出频率保持原配置，参考输入与输出的绝对相位契约发生变化，详见[PLL与SDRAM布线复核](clock-routing-20261028.md)。后续为补偿 ODDR 转发延迟，仅系统 PLL C2 的40 MHz源相位由180°改为135°，并加入持久的输出生成时钟约束，详见[SDRAM转发时钟修正](sdram-forward-20261028.md)。Verilog、IPC及禁用VHDL参数一致；参考目录 `05_lab_ex/` 未随此改动。下面按日期保留的历史来源描述不代表新配置仍与原始音频PLL逐字节一致。

# 整合后的来源变更（2026-10-11）

以远端 PR #1 的 `50fea941512f3aabfafb93ad200f84abf84bd79b` 为历史基础，保留队友提交。加入本地已验证的40MHz PLL/刷新/BMP修复，相关独立例程也保留这些修改。

主工程SD/BMP/帧缓存源码从原本的例程路径收口到 `project/vendor/SD`；仅主工程版帧读控制器增加帧边界信号和同步编号参数。图片发布模块 `rtl/frame_buffer_publish.v` 新增稳定数据请求/确认跨域，`rtl/SD/sd_card_bmp.v` 等待读端确认才解除忙状态。

`reset_release.v` 新增ready输入，raw reset与就绪电平分离，减少复位来源歧义；`constraints/reset_publish.sdc` 只豁免真正的第一级控制同步路径，并给缓冲编号总线加25ns上限。PLL包装保留PR的lock端口。HDMI加密/SDRAM加密核未修改，仍从原例程引用。

本次构建扩展到place/route/bitgen，所有输入/报告/位流哈希由 `verify_td.py` 保存。新增媒体/复位测试并统一到 `run.py`，没有额外处理器或文件系统实现。

以下为PR整合前的来源记录，保留作历史；以本段和整合验证报告解释当前活动输入。

---

# 基础工程源码来源

本文件记录 `project/` 与原仓库参考工程的关系，供审查源文件、IP 和约束变更。构建步骤见 [工程说明](../README.md)，接口行为见同目录各模块契约。

## 原仓库基线

本次工作以私有仓库 `wustarlance/cpr-fpga-2026` 的 **20026ba86faa6a7ce63be6195f27a458a12e15fd** 快照为基线。该快照来自登录后的 GitHub 下载包；本地初始化的 Git 提交用于审查快照差异，不是远端提交历史。发布使用从远端 `main` 创建的 `codex/cpr-foundation` 分支，以网页上传已审查的差异文件，并通过 PR 审阅共享文件。

快照中的 `project/project.al` 尚未登记主工程 RTL。`05_lab_ex/lab_ex5_i2s` 则包含 HDMI 音频、TF 卡读 BMP 和 SDRAM 帧缓存参考链路。本次保留 `05_lab_ex/` 原内容，在 `project/` 登记可构建的主工程，并复用此前本地 `HX4S20C_CPR_Basic` 中的基础模块与修复，再增加 ADC 采样和事件接口。

## 源文件映射

| 主工程文件 | 来源和变更范围 |
|---|---|
| `rtl/top_tf_hdmi_audio.v`（模块 `top`） | 从参考顶层和本地基础工程整合。保留 HDMI/测试音、SD/BMP 和 SDRAM 链路；加入模式控制、训练反馈、亮度和固定 OSD；选择按键演示或 ADC 路径 |
| `rtl/top_adc.v` | 新增包装顶层，复用 `top`，固定 `USE_ADC=1`；板卡端口名与管脚表相同 |
| `rtl/timebase.v`、`input_filter.v`、`reset_release.v` | 迁入本地基础工程中的计时、输入去抖和各时钟域复位释放逻辑 |
| `rtl/cpr_control.v`、`training_core.v` | 迁入三模式控制与训练计数；新增已完成按压事件输入，使 ADC 峰值完成事件接入同一计时/评级接口 |
| `rtl/brightness_rgb.v`、`rate_display_lut.v`、`cpr_overlay.v` | 迁入基础显示逻辑；ADC 模式显示未标定压力标识，避免把码值直接标作厘米 |
| `rtl/video_rgb_to_axis_640x480.v` | 在参考模块上修正行计数，保证 `last` 对应每行第 640 个有效像素 |
| `rtl/SD/sd_card_bmp.v` | 在参考模块上扩展上一张与自动模式控制；避免新加载使用旧的 `bmp_ready`，并等待对应帧写完成后提交显示缓冲区 |
| `rtl/adc_ctrl.v` | 新增纯 RTL ADC 请求/EOC/超时控制；按官方数字时序契约实现整数采样周期和稀疏采样 PD 动作 |
| `rtl/sample_mailbox.v` | 新增完整 12 位字的请求/应答跨域传输，忙时丢样锁存溢出；共同复位取消在途事务 |
| `rtl/pressure_normalize.v`、`peak_detect.v` | 新增压力码归一化、四点均值和完整释放后的一次按压事件检测；不直接复制方案中“下降 25% 即结束”的伪代码 |
| `rtl/cpr_sensor_path.v` | 新增采样链集成与粘滞故障抑制；ADC 原语由板卡顶层实例化 |
| `ip/sys_pll.*`、`ip/video_pll.*` | 从例程的 PLL 配置/包装复制，暴露原有 `extlock`；输出频率、分频与相位保持原值；补齐 IPC 列出的禁用 VHDL 包装文件以满足 TD 的存在性检查 |
| `vendor/sdram.v`、`vendor/include/` | 迁移原例程依赖工作目录的 include 文件位置，使主工程从 `project/` 构建；不修改 SDRAM 时序设计或加密核算法 |
| `constraints/pin.adc` | 保留参考 HDMI/SD/时钟/复位管脚，依据 HX4S20C V1.0 官方板资料加入板载和外部输入；不采用其他封装或厂商的引脚表 |
| `constraints/timing.sdc`、`adc_mailbox.sdc` | 声明 50 MHz 输入并派生 PLL 时钟；保持像素与串行时钟同时工作，保留 FIFO Gray 指针时序约束；ADC 专用文件仅在脚本选择 `top_adc` 时加载，为完整 12 位邮箱稳定数据路径加界限，不放宽 SDRAM DQ setup/hold |
| `project.al`、`build.tcl`、`verify_td.py` | 登记主工程源码、IP 和约束，以 EG4S20BG256 为目标；脚本可选择 `top/top_adc`，失败退出，输出综合报告；Python 运行器保存两种顶层的源码、工具和报告哈希及诊断 |
| `tests/sim/` | 新增或迁入编译产品 RTL 的自检 TB 与标准库 Python 运行器；日志含实际源文件哈希，空跑和失败标记不能通过 |

表中路径相对 `project/`；`tests/sim/` 相对仓库根目录。实际编译清单以 [project.al](../project.al) 和 [仿真运行器](../../tests/sim/run.py) 为准。

## 保留的参考依赖

主工程直接引用 `05_lab_ex/lab_ex5_i2s/src/` 的 I2S 接收、测试音、音频 ACR、HDMI PHY/LVDS 包装、加密 HDMI 核、SD SPI/扇区/BMP、帧读写、显示时序、数码管和 SDRAM 加密模块。音频 PLL 和帧缓存两种异步 FIFO 的生成配置也继续引用该目录。

FIFO 除了 `.ipc` 配置和 HDL，还需要生成的 `.tcl` 约束；[build.tcl](../build.tcl) 用 `read_sdc -ip` 分别加载读、写 FIFO 的约束。不能省略 `05_lab_ex`，不能只复制顶层后宣称工程独立，也不能用一条宽泛的异步时钟分组掩盖这些路径。

TD 6.2.168116 在加载 PLL IPC 时仍检查 `GeneratedFiles` 中 `Enable="false"` 的 `.vhd` 是否存在。缺少文件会产生 `PRJ-7002` 严重告警；只改变 `create_VHDL` 不能消除。本次保留两个 IPC 并补齐对应 VHDL 包装，端口和参数与实际启用的 Verilog 包装一致。VHDL 仍禁用，未执行独立 VHDL 编译。

`project/vendor` 只处理 include 路径；官方受保护 HDL 不解密。仿真中的 `eg_phy_adc_timing_model.v` 是依据公开数字时序编写的原创行为模型，不是官方 ADC 模型的替代实现，也不进入 TD 产品综合清单。

## 资料与验证边界

器件和模拟接口依据官方 EG4S20 数据手册、TN304 v1.3《EG4S 内部 ADC 使用指南》及 HX4S20C 板卡手册/原理图；TD/IP 配置依据当前安装工具、实际生成包装和约束文件。原始 PDF 保持原格式，本次没有将其转为 Markdown。

CH1 使用 M10 经 RN23 到 J1 第 16 脚。ADC 复用已有约 12.295082 MHz 音频时钟；训练与 UI 在 25 MHz 视频时钟域。ADC 压力阈值仍为实验码值，参考电压、有效输入区间、噪声、FSR 极性和机械位移映射需要实测。

此来源记录说明文件沿革，不代表赛题验收或硬件签核。旧参考工程的位流/时序报告不能证明新增主工程通过；最终结果需关联本次源码哈希、工具版本和报告。共享顶层、工程文件与约束变更按仓库协作约定通过 PR 审查。
