# 中文提示与教程接入（2026-10-16）

默认 UI_LANGUAGE_ZH=1，加入中文提示和四张教程 BMP。接线接口、素材顺序、资源和验证边界见 [中文界面与教程](docs/chinese-ui.md)。当前是基于 PR #3 的本地开发版本；队员缩放/缓存代码尚未合入，旧构建记录不代表本次版本。

---

# 训练页面管理接入（2026-10-15）

进入训练自动请求第二张胸外按压教程，外接按键或 ADC 模式可前后翻页，退出恢复进入前真正显示的浏览页。加载时保留旧图，页眉显示页码及 L/M/E 状态；默认板载模拟按压不会带动翻页。默认 30 项 RTL 自检，操作、素材顺序、CDC 和验证边界见[训练页面管理](docs/training-pages.md)。通过分支 `codex/cpr-sd-pages-20261015` 提交 PR；下方统计为对应历史版本。

---

# SD恢复接入（2026-10-15）

SD读取现在包含令牌/字节超时、读CRC、取消、整图有限重试和旧帧保留。重试耗尽时状态位为E，可用上一张/下一张重新尝试。默认27项RTL自检，协议、参数、故障场景和验证边界见[SD恢复说明](docs/sd-recovery.md)。下方较早的版本与构建状态保留为历史记录。

---

# 显示功能接入状态（2026-10-13）

训练模式采用384像素教程区与256像素反馈面板；画面坐标、素材工具、23项数字自检及本次TD限制见[训练底图修改说明](docs/training-layout.md)。下方2026-10-11整合统计属于历史版本。

---

# HX4S20C 心肺复苏训练终端：整合工程

主工程入口为 `project/project.al`，顶层 `top`（按键演示）或 `top_adc`（未标定压力输入）。工具为安路 TD 6.2.1 SP1 / 6.2.178840，器件 EG4S20BG256，HDMI_B 输出。

本工程整合 PR #1 的训练、ADC、OSD、复位和自检，与本地 SDRAM 40 MHz、刷新参数及 BMP 扫描流水化修复。媒体层继续用原始扇区扫描；尚未实现 FAT32、语音/音乐、缩放、频谱或转场。ADC 数字链可构建，模拟输入与机械深度仍未标定。

## 目录与依赖

- `rtl/`：应用、训练、ADC、OSD、帧发布逻辑。
- `ip/`：系统/视频 PLL 配置与配套 HDL；SD 时钟100 MHz、SDRAM 40 MHz/180°、像素25 MHz、串行125 MHz。
- `vendor/SD/`：主工程实际编译的 SD/BMP/帧缓存源码，包含扫描分拍及读端切换边界。
- `vendor/include/`：SDRAM 刷新定义及兼容包装。
- `constraints/`：管脚、相关时钟、局部 CDC 与复位约束。
- `docs/`：数字接口、来源及本次验证结果。

`05_lab_ex/lab_ex5_i2s/src` 仍提供 HDMI 加密核、部分音频模块、FIFO IP 和 SDRAM 加密核，必须与 project 一起检出。其媒体 SD 源码不再作为主工程的隐式可变副本；主工程媒体修改请改 `project/vendor/SD`。独立例程仍在 `05_lab_ex` 下运行。

## 验证与构建

在仓库根目录运行全部自检：

```bash
python3 tests/sim/run.py --all --self-test-runner
```

在 `project/` 运行完整构建：

```bash
cd project
CPR_TOP=top td build.tcl
CPR_TOP=top_adc td build.tcl
```

位流分别为 `project/build/top/top.bit`、`project/build/top_adc/top_adc.bit`。脚本检查实际 PLL 周期和最终 setup/hold WNS、TNS，时序失败返回非零；不下载硬件。需要只综合时用 `CPR_STAGE=synth`。

一次核对两个顶层并保留源码/日志/位流哈希：

```bash
python3 project/verify_td.py --td /usr/local/bin/td --stage full
```

默认 GUI 的 `syn_1 / phy_1` 重建可在 project 运行 `td rebuild.tcl`。ADC 构建必须用 `CPR_TOP=top_adc td build.tcl` 加载并验证 ADC 专用约束；只在 GUI 中改顶层不等价。关闭旧工程窗口，再打开 `project/project.al`；旧 `project/td_project` 已归档，不应继续使用。

## 使用

KEY1 复位；KEY4 在教学、自动展播、训练之间循环；KEY2 在教学模式下一张、自动模式暂停/继续、默认训练模式按下并释放模拟按压；KEY3 上一张。默认按压档由 SW1～SW4 选择，0000 代用目标档，0001 浅、0011/0111 目标、1111 深。训练频率以完成释放事件间隔计量。

ADC 模式使用 CH1（M10，J1 第16脚），复用约12.295 MHz音频 PLL。当前归一化 baseline=3000，触发150、释放100、评级800～1600均为未标定压力码，OSD 显示 `PRESS UNCAL`。不能将它们直接解释为厘米。KEY2 在 ADC 模式不产生模拟按压。

有外部按键时，`top` 的 `USE_EXTERNAL_IO=1` 可选择五按键及四接触输入，具体见 pin.adc 和原 PR 输入契约。默认板载模式尚无亮度/独立清场按键。四图素材为640×480、24位无压缩、正高度BMP，仍要求受控扇区布局。

帧发布流程与复位契约见 [frame-buffer-contract.md](docs/frame-buffer-contract.md)。必须等读端在帧边界确认新缓冲区后，才释放旧缓冲区；不再仅凭写完认为切图已经完成。

## 已知限制

数字测试、完整构建和静态时序通过不等于实际显示/ADC/机械已通过。加密 SDRAM 刷新时的请求行为、长时间读写、板级 I/O 和 HDMI 接收端仍需上板验收。TD 可能报告内置 SDRAM 宏在中间 ECO 布局重新定位；验证脚本只在完整 route/bitgen 成功时单独记录这个精确诊断，其他错误或严重告警仍拒绝。

本次结果见 [integration-verification.md](docs/integration-verification.md)。位流、日志及工具不进 Git。
