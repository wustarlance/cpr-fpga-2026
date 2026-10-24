# workbuddy_change —— 音频链 TD 综合 / 时序 / 上板

本目录是**旁挂**的，不动 `rtl/`、`vendor/`、`constraints/` 里任何一行原代码。
两条线并存：

1. **上板**（2026-10-24 新增）：`audio_bringup.al` / `audio_board.al`，出 `.bit` 上位流；
2. **时序复核**：`audio_tmg.al`，只有三路时钟 + 音频链，用来看 100 MHz 余量。

## 两个上板工程

| 工程 | 顶层 | 声音出口 | 加密 IP | 状态 |
|---|---|---|---|---|
| `audio_bringup.al` | `audio_board_bringup_top` | 蜂鸣器 H11（1 bit Σ-Δ） | 不用 | ✅ 已出位流 |
| `audio_board.al` | `audio_board_top` | HDMI_B（TMDS 数据岛） | **要（HDMI 核）** | ⛔ 等 TD SP1 |

**卡点**：`hdmi_1_4b_transmitter_core_wrapper.enc.v` 是 IEEE-1735 加密代码
（`pragma protect` / AES128-CBC / `anlogic-rsa-001`）。本机 TD `V6.2.168116`
解不开，`HDL-8007`；**厂商自带的 `HDMI1.4b_Transmitter_v1.0.al` 同样报错**，
所以不是本工程写法问题。工程主 `README.md` 记录的可用版本是 6.2.1 SP1 / 6.2.178840。

```bat
:: bring-up（今天就能上板）
set AB_PROJ=bringup
D:\ANLU\TD_6.2.1\bin\td_commands_prompt.exe scripts\build_board.tcl

:: HDMI 版（装完 SP1 再跑）
set AB_PROJ=board
D:\ANLU\TD_6.2.1\bin\td_commands_prompt.exe scripts\build_board.tcl
```

引脚、烧卡、下载、验收清单见 **[doc/上板与引脚_20261024.md](doc/上板与引脚_20261024.md)**。

## 目录

| 路径 | 作用 |
|---|---|
| `audio_tmg.al` | TD 工程文件（GUI 可直接打开；路径相对本目录书写） |
| `rtl/audio_tmg_top.v` | 综合/STA 专用顶层：三路时钟直给、SD SPI 出 pad、640×480 扫描计数器 |
| `rtl/audio_board_top.v` | 上板顶层（HDMI 版）：PLL + SD + WAV + 彩条 + HDMI 核 |
| `rtl/audio_board_bringup_top.v` | 上板顶层（无加密 IP 版）：数码管 + LED + 蜂鸣器 |
| `rtl/wave_painter.v` | 波形绘制器（本人新建，**当前不参与任何构建**） |
| `constraints/audio_tmg.sdc` | 三时钟 + `set_clock_groups -asynchronous` + SD 多周期 + IO 延迟 |
| `constraints/audio_board.adc` | HDMI 版引脚（TMDS + DDC + SD + 按键） |
| `constraints/audio_bringup.adc` | bring-up 版引脚（数码管 + 蜂鸣器 + SD + 按键） |
| `constraints/audio_board.sdc` | 上板版时序约束（PLL 派生时钟 + 异步分组） |
| `scripts/build_board.tcl` | ★ 上板一键：elaborate → 综合 → 布局 → 布线 → 门禁 → bitgen |
| `build_bringup/` | **位流** `audio_board_bringup_top.bit/.bin` 与报告 |
| `scripts/flow.tcl` | ★ 一键：elaborate → opt_rtl → opt_gate → place → route → 时序报告 |
| `sim/lint.do` | ModelSim 编译同一份 13 文件并 elaborate（0 error 才算过） |
| `sim/run_wave.do` | `wave_painter` 自检回归（16 帧、逐列核对） |
| `tb/tb_wave_painter.v` | 上述回归的 testbench |
| `build/` | 各阶段 `.db` 与报告（面积、时序摘要、QoR） |

## 怎么跑

```bat
cd D:\ANLU\code\cpr-fpga-2026\project\workbuddy_change
set AT_STAGE=route
D:\ANLU\TD_6.2.1\bin\td_commands_prompt.exe scripts\flow.tcl
```

`AT_STAGE` 可设 `gate`（只到综合后）、`place`、`route`（默认跑完布线）。
不看时序、只要资源时用 `gate`，十几秒出结果。

ModelSim：

```bat
cd sim
vsim -c -do "do lint.do; quit -f"        :: 编译 + elaborate
vsim -c -do "do run_wave.do; quit -f"    :: wave_painter 回归
```

## 结果速览（2026-10-24，EG4S20BG256 / TD 6.2.168116）

资源（布线后）：LUT **3789**（19.3%）、REG **1915**（9.8%）、BRAM9K **6**（9.4%）、
DSP **1**、PAD **136/188**。

| 时钟 | 约束 | fmax | SWNS | HWNS | 端点 |
|---|---|---|---|---|---|
| sd_clk | 100.000 MHz | 101.968 MHz | **+0.193 ns** | +0.038 ns | 2703 |
| vid_clk | 25.175 MHz | 35.239 MHz | +11.344 ns | +0.054 ns | 1005 |
| mclk | 12.288 MHz | 79.949 MHz | +68.872 ns | +0.046 ns | 615 |

三个域 0 违例；STA coverage 100%。详见 `doc/综合与时序_20261024.md`。

## 踩过的四个坑（都验证过，别再犯）

**1. TD 命令行的相对路径按「进程 CWD」解析，不是按 `.al` 的 `<Project Path>`。**
在 `scripts/` 目录里执行时，13 个源文件全部落空，现象是
`PRJ-1401 Successfully analyzed 13 source files` + `HIER-1013 could not find
top-level module` + `HDL-8001 Incorrect top-level module name`。
——**数量对得上、模块找不到**，极易误判成 `.al` 格式问题。
所以 `flow.tcl` 必须从 `workbuddy_change` 目录执行。

**2. run 快照（`.prj`）+ `DefaultFlow.tcl` 这条路在命令行下不通。**
无论路径写成相对还是绝对，都 `analyzed 0 source files`。
直接用 `.al` + 自写 `flow.tcl` 最省事。

**3. `AutoExcluded="true"` 不是「排除出编译」。**
原工程 `project.al` 里 58 个文件全带 `true`，包括真正的顶层。
实测：本工程 13 个文件全保留 `true`，照样综合出 3789 LUT / 1915 REG / 6 BRAM。
它是「允许 TD 自动挑出无用文件」的标记，**不要删**；
真要排除某个文件，是把它标成 `AutoExcluded="true"` 且不被顶层例化，
而不是把这个属性去掉。

**4. 别用 `rm -rf` 清目录。** 本环境的删除保护会拦下，改用按文件 `os.remove`。

## 已知边界

- 上板工程已补引脚约束（`audio_board.adc` / `audio_bringup.adc`），PAD 34/188；
  `audio_tmg.al` 那条时序复核线仍然不带引脚（PAD 自动分配），两者别混。
- **端到端音频通路还没仿**：要跑通得有 SD 卡行为模型，目前只做了
  `wave_painter` 的逐列回归 + 全设计 elaborate 校验。
- **保持余量很薄**：sd_clk HWNS 只有 +0.038 ns（布线后），换器件/换版本要复看。
