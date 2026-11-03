# 心肺复苏训练终端 · 设计说明

> 本文是作品的**实现文档**：RTL 结构、模块契约、关键取舍与验证边界。
> 建议阅读顺序：根 README（总览）→ 本文「速览」→ [docs/README.md](docs/README.md) 文档索引 → 四份核心契约。

## 速览

| 项 | 内容 |
|---|---|
| 构建入口 | `cd project && CPR_TOP=top_adc td build.tcl`（`td` = 安路 TD 6.2.168116 命令行） |
| 顶层 | `top`（基础版）/ `top_adc`（带按压训练，演示用这个） |
| 生成物 | `build/top[/_adc]/top[_adc].bit`，时序门禁不过不生成 |
| 资源 | LUT 15.3k / 19.6k，BRAM 57 / 64 |
| 时序 | `top_adc` setup **+0.111 ns** / hold **+0.011 ns**（2026-11-01 完整构建） |
| 仿真 | `python3 tests/sim/run.py --all` → 67 项 RTL 自检 + 5 项运行器控制 |
| 严格诊断 | PLL/SDRAM 关键告警与板级 I/O 审查**尚未清零**，见 [td-critical-audit](docs/td-critical-audit-20261025.md) |

**只看这四个文件就能理解核心：**

| 文件 | 作用 |
|---|---|
| `rtl/top/top_tf_hdmi_audio.v` | 顶层连线：视频链、音频链、ADC、OSD 怎么接在一起 |
| `vendor/SD/bmp_read_scaled.v` | BMP 读取 + 加载时等比缩放 + 补边区合成 |
| `vendor/SD/bmp_blur_background.v` | 非 4:3 图的模糊背景引擎（cover→面积平均→盒式模糊→双线性） |
| `rtl/training_core.v` | 按压计数、间隔、评级、停顿与换人倒计时 |

**根目录里哪些脚本参与交付构建**：

| 脚本 | 用途 | 交付相关 |
|---|---|---|
| `build.tcl` | 正式构建（含时序门禁） | ✅ 唯一入口 |
| `project.al` / `filelist.f` | TD 工程与源文件清单 | ✅ |
| `verify_td.py` / `td_report_checks.py` | 构建报告审计 | ✅ 辅助 |
| `build_baseline.tcl` | 上游基线复现（读 `vendor/hdmi_lab` 依赖） | ⬜ 历史 |
| `build_fast.tcl` / `rebuild.tcl` / `build_bit*.bat` / `build_project.bat` | 实验性布局参数与批处理 | ⬜ 历史 |
| `audit_interfaces.py` / `audit_physical.py` / `audit_physical.tcl` | 接口与物理审计实验 | ⬜ 历史 |
| `scripts/res_probe/` | 心跳正弦查表的资源/精度探针 | ⬜ 历史 |

> 2026-11-01 提交版本已删除 ADC 标定探针工程（`probe/`、`probe.al`、`build_probe.tcl`）。
> 它只用于上板调 CH4，不参与产品构建；当时用法（数码管读码值、8 通道扫描、峰值诊断）记录在
> [adc-contract.md](docs/adc-contract.md) 与提交历史里。

---

## 历史状态记录（按日期，供追溯）

> 以下各段是每轮改动当时的结论，数字只代表当时版本；当前状态以上方「速览」为准。

> **2026-11-01 开机音画与K6/K7修正**：视频PLL锁定后独立输出LOGO；LOGO期间静音并暂停WAV位置，完整教程帧送出后再播放。K6仅调对比度、K7仅切字幕。67项RTL与5项运行器检查通过；两个顶层生成位流，内部建立/保持余量为正，原严格诊断保留。ADC修正版13:01临时下载SRAM，复位后的音画顺序和按键分离已由操作者确认；未写Flash/TF，真实断电冷启动时间未测。见[修改与验证范围](docs/startup-av-20261101.md)。
>
> 2026-10-26：时序优化一轮（`bmp_read_scaled` 的 `.ce` 树）。`top` setup WNS **+0.123 → +0.188 ns**，
> `top_adc` **+0.196 → +0.168 ns**，两顶层 hold 仍为 +0.010/+0.011 ns，位流已重生成；58 项 RTL 自检全通过。
> 剩余余量的天花板是 82% slice 占用导致的布线碎片化，不是逻辑级数——证据与被否掉的 7 组 P&R 配置
> 见下方「2026-10-26 的一轮时序优化」小节。
> **上板结果（2026-10-26 20:30）**：用这批参数出的位流（18:29、20:06 两份，md5 不同、时序数字相同）在板上
> **数码管正常、HDMI 全黑且无声音**；14:29 那份旧位流当时可用，两者的 RTL 完全一致（`rtl/`、`constraints/`、
> `vendor/` 在 14:29~18:40 之间一个文件都没改），只差 P&R 参数。所以实验性 P&R 选项已全部撤掉、回到基线参数，
> 带说明的副本见 `build_baseline.tcl`；实验参数只留在 `build_fast.tcl` 里等复验。
> 合并 `origin/main` 后 `build.tcl` 另取了 main 的**约束读取顺序**版本（WAV CDC 约束挪到 gate 映射之后、
> 可选 loop/总帧数端点按存活情况绑定），该版本不含任何 P&R 实验选项。
>
> **2026-10-25 TD关键告警排查**：完成两顶层反馈端点/宏位置查询，并用23 LUT、32寄存器的小工程复现SDRAM重定位和本地时钟分支告警；同流程去掉计数器的对照为0条关键告警。固定位置未关闭问题，产品RTL/PLL/约束未改，三类告警仍待厂家确认。见[复现、对照及验证边界](docs/td-critical-audit-20261025.md)。
>
> **2026-10-25 波形／音量条与轮播转场**：已整合 main `7235989` 的 WAV 与共享SD路径；18项功能检查、3项预期故障注入通过。TD两顶层生成位流，setup +0.120/+0.159 ns、hold +0.003/+0.004 ns。原PLL／SDRAM关键告警保留，严格检查仍 failed、板级 I/O 为 conditional，新位流未上板。见[功能、预览与当前验证](docs/audio-and-transitions.md)。
>
> 2026-10-24：完成 [SD/HDMI 离线时序预算与自检](docs/io-timing-budget.md)，SD 正常传输改为约 16.67 MHz；现有 TD 6.2.168116 完整生成两顶层位流、内部 setup/hold 为正。6 项 RTL、27 项 Python 检查通过，2 项故障注入按预期失败。严格检查仍 failed、板级 I/O 为 conditional；未上板，下方历史通过记录不替代本次结果。
>
> 2026-10-23：TD 6.2.168116 已完成两个顶层的新一轮布局布线，修复页面/ADC邮箱的SDC回放绑定，并增加约束覆盖门禁；严重告警和接口审查仍未完成，严格验收为failed。见[本轮TD验收记录](docs/td-acceptance-20261023.md)。
>
> D123白线修正、按键映射及两轮SRAM观察见[白线修正说明](docs/white-lines-20261023.md)。本轮TD候选未下载上板，未写Flash。

> 本地修复版（2026-10-17）：频率与刷新互锁改动见 [修复说明](docs/display-fixes-20261017.md)。41 项 RTL 及 5 项运行器检查通过；本次尚未完成 SP1 布局布线及实板复验。下方构建状态属于修复前的主分支基线。

> **当前状态（2026-10-18）**：44 项 RTL 自检与 5 项运行器控制全部通过；TD 完整构建两个顶层均通过，零违例端点（`top` SWNS **+0.116 ns**、`top_adc` **+0.104 ns**），位流已生成，可上板。PR #3/#4、四槽全缓存、加载时缩放、模糊补边、中文界面与音频节拍器均已合入当前工作区。
>
> 下方按日期排列的小节是各次接入时的历史记录，其中的自检数量（23/27/30/39 项）反映当时版本，**不代表当前状态**。当前数量以本节为准。

---

# 中文提示与教程接入（2026-10-16）

默认 UI_LANGUAGE_ZH=1，加入中文提示和四张教程 BMP。接线接口、素材顺序、资源和验证边界见 [中文界面与教程](docs/chinese-ui.md)。缩放缓存代码与中文界面已在同一个 `main` 上合入并共同验证，不再是两套分立版本。

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

主工程入口为 `project/project.al`，顶层 `top`（按键演示）或 `top_adc`（未标定压力输入），器件 EG4S20BG256，HDMI_B 输出。团队历史工程元数据为 TD 6.2.1 SP1 / 6.2.178840；本次使用用户现有官方 TD 6.2.168116 完整构建，工具版本与结论见上方当日记录，升级 SP1 不是本次前提。

`top` 和 `top_adc` 均提供综合期参数 `ENABLE_AUDIO`，默认 `1` 保持 HDMI 音频输出；设为 `0` 会关闭 HDMI 音频采样与 ACR 包。修改参数后需重新综合并生成位流。音频 PLL 保持运行，因为其时钟也供 ADC 采样链使用。

教学浏览按当前显示页选择 WAV，自动展播使用公共曲目 `FREE_SONG`。`rtl/audio/wav_audio_sd_top.v` 经 `rtl/SD/sd_sec_arbiter.v` 与 BMP 共用 `sd_card_top`，仲裁优先服务 BMP。五个音轨首扇区统一定义在 `rtl/audio/wav_track_select.v`：`PICTURE_1..PICTURE_4` 为 12000 / 123000 / 250000 / 370000，`FREE_SONG` 为 500000。

`I_audio_sel` 为 3 位选曲码：0..3 对应 `active_read_idx`，4 对应自动展播曲目。页索引在帧边界更新；选曲码经过两级同步和 8 拍稳定过滤，避免跨位翻转造成误选。确认换曲后，`wav_audio_path` 执行 abort→start，重新锁存扇区并清空两侧 FIFO。WAV 经 `pcm_fifo` 进入约 12.295082 MHz 音频域，由 `pcm_player` 送入 HDMI 数据岛；ACR 随音频流输出。自动展播暂停翻页时，背景曲继续播放。

训练心跳由 `rtl/audio/heartbeat_synth.v` 片内合成，不读 TF 卡。每拍包含 150 Hz / 25 ms 与 190 Hz / 35 ms 两个短音，第二声在 70 ms 处开始，幅度为第一声的 65%；节拍为 110 BPM，约 545 ms。两路音源共用音频帧节拍。

`wav_audio_path` 在 WAV 与心跳之间二选一，不混音。`I_heart_en`、`I_mute` 经两级同步进入音频域；退出训练时，心跳约用 0.67 ms 将包络降为零，`O_busy` 释放后再切回 WAV。训练期间 `I_play` 为 0，WAV 读请求和播放位置暂停，SW4 不改变其状态；退出后继续原曲目。切回 WAV 时仍可能存在幅度阶跃。旧淡化实验保存在 `attic/audio-fade/`，实现细节见 [心跳合成](docs/heartbeat-synth-implementation.md)。声音仅经 HDMI 输出。

SW4（C5）控制 WAV 暂停／继续：暂停时拉低 `I_play`，保留 FIFO 和播放位置。对比度由外接 K6 逐档调节，复位为 100%，循环为 50%→75%→100%→125%→150%；外接 K7 独立开关字幕。外部 IO 版本中 SW1..3 空闲；板载演示版本仅在按住 KEY1 时将其作为触点输入（`app_depth_raw`）。

Windows 下可运行仓库根目录的 `tools/烧音频到TF卡.bat`。脚本申请管理员权限，列出物理盘与 WAV 文件，再按音轨编号 1..5 选择目标；5 对应 `FREE_SONG`。`tools/burn_wav.py` 从 RTL 参数读取首扇区，先只读预检，确认后写入。应按实际容量和设备信息核对目标盘，不能仅凭磁盘编号选择。

命令行依次使用 `python tools/burn_wav.py --list`、`--device \\.\PhysicalDriveN --track 5 --dry-run`，确认预检结果后将 `--dry-run` 换为 `--confirm`。`--sector N` 可指定裸扇区，但不校验 RTL 音轨表。裸扇区写入会覆盖对应区域的原有数据；电脑提示格式化时不要格式化该卡。

新增[音频波形与音量条、自动轮播淡入淡出](docs/audio-and-transitions.md)：监测与 HDMI 共用的最终门控 PCM，条带只占最后 16 行；自动换页先淡出到黑，在原帧边界发布完成后淡入。状态文字在渐变后叠加。`ENABLE_AUDIO_VISUALIZATION`、`ENABLE_SMOOTH_TRANSITIONS` 默认开启，可分别编译关闭；没有新增 SDRAM 图像并发读取。

本工程整合 PR #1 的训练、ADC、OSD、复位和自检，与本地 SDRAM 40 MHz、刷新参数及 BMP 扫描流水化修复。媒体层继续用原始扇区扫描。当前 BMP 路径支持正高度、24 位无压缩、宽≤2048/高≤1536 的图片，加载时最近邻等比缩放并居中。需要补边的图片在加载阶段额外读取一遍源图，生成 32×24 cover 裁切背景，经区域均值降采样、三遍3×3盒式模糊、双线性放大并保留75%亮度，再盖上清晰前景写入 SDRAM；无补边图片仍走原来的单遍缩放。前四张会预载入四个固定 SDRAM 槽位，四槽就绪后手动/自动切换不再访问 SD 卡或重新计算模糊背景。设置顶层参数 `BLUR_BACKGROUND=0` 可恢复固定深蓝灰补边并取消双遍加载。实现细节（cover 裁切、32×24 分数边界面积平均、3 遍盒式模糊、8.8 定点双线性采样、资源与时序取舍）见[模糊补边背景](docs/blur-background.md)。

尚未实现：FAT32 目录与碎片文件、top-down/压缩 BMP、FFT 频谱可视化。已增加 PCM 波形/音量条及自动轮播的淡出淡入。前景仍使用最近邻采样；补边背景已在 RTL 中实现区域均值、三遍盒式模糊、双线性放大和亮度压暗。ADC 数字链可构建，模拟输入与机械深度仍未标定。

## 目录与依赖

- `rtl/`：应用、训练、ADC、OSD、帧发布逻辑。
- `ip/`：系统/视频 PLL 配置与配套 HDL；SD 时钟100 MHz、SDRAM 40 MHz/180°、像素25 MHz、串行125 MHz。
- `vendor/SD/`：主工程实际编译的 SD/BMP/帧缓存源码，包含分辨率适配、行填充、扫描分拍及读端切换边界。
- `vendor/include/`：SDRAM 刷新定义及兼容包装。
- `constraints/`：管脚、相关时钟、局部 CDC 与复位约束。
- `docs/`：数字接口、来源及本次验证结果。

HDMI 加密核、FIFO IP 与 SDRAM 加密核已内置到 `project/vendor/hdmi_lab/`（原在厂商例程 `05_lab_ex`，提交版已移除该目录）。其媒体 SD 源码不再作为主工程的隐式可变副本；主工程媒体修改请改 `project/vendor/SD`。

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

`td` 指 `/usr/local/bin/td`（指向 TD 6.2.1 SP1 的启动器），不要用 `bin/td`。

### 命令行构建的三种用法

```bash
cd project

CPR_TOP=top     td build.tcl   # 默认演示版：板载按键模拟按压。约 90 s
CPR_TOP=top_adc td build.tcl   # ADC 采集版：真实按压盒。约 146 s
CPR_TOP=top CPR_STAGE=synth td build.tcl   # 只综合不布局布线，约 55 s
```

`CPR_STAGE` 未设置时等于 `full`（综合→布局→布线→时序检查→生成位流）；`synth` 只跑到 `optimize_gate`，**不生成位流**，适合快速确认代码能否综合。

### 布局布线的 effort

> **2026-10-26 22:00 状态**：这批参数**已从 `build.tcl` 回退**（回退后的原样内容见
> `build_baseline.tcl`），只保留在 `build_fast.tcl` 里作为待复验的实验配置。原因见文首
> 「上板结果」：实验参数出的位流上板后 HDMI 全黑、无声音，而同一套 RTL 用基线参数出
> 的 14:29 位流可用。下面的数字都是**实验配置**的结果，要出能烧的位流请用 `build.tcl`
> 或 `build_baseline.tcl`。

`build_fast.tcl` 用的是 TD 官方的 **TimingHigh** 策略
（`TD/doc/strategies/official_strategy_ph1.json`），外加综合侧的 **LogicLevelOptimize**
（`gate map_mode balance_explore`、`mapper_lut_delay 2200`）；基线 `build.tcl` 只有
`place opt_timing high` 一条，其余全部是 TD 默认。

来由（2026-10-26）：加入训练心跳后 LUT 到 70.35%，`sd_card_clk`（100 MHz）上那两条 BMP 读取锥被挤成负余量：

- `top`：AFIFO 满标志 → `bmp_read_scaled` 的 OUT_SEND 使能锥 → `h_rem.ce`，8 级（4 ADDER + 4 LUT），**−0.217 ns**
- `top_adc`：`bmp_blur_background` 的 crop 比较 → `sd_sec_read_addr.ce`，6 级，**−0.101 ns**

只留 `place opt_timing high` 救不回来：补上 `post_place_opt high` + `route post_route_opt high` 把 `top` 拉回 +0.140，
`top_adc` 还得靠综合侧先少落一级（`map_mode balance_explore`）才过。`TimingUltra`
（`hfn_opt_effort high` + `postrt_opt_extra_round 4`）在 `top_adc` 上反而更差（−0.113），没有采用。

### 2026-10-26 的时序结果（心率训练版，实验参数）

> 下表出自实验配置 `build_fast.tcl`。基线 `build.tcl` 对应的是 `top` +0.128 / `top_adc` +0.196
> （hold 同样为正），也就是"能上板"的那一组。

| 顶层 | setup WNS | hold WNS | 位流 |
|---|---|---|---|
| `top` | **+0.188 ns** | +0.010 ns | `build/top/top.bit` |
| `top_adc` | **+0.168 ns** | +0.011 ns | `build/top_adc/top_adc.bit` |

上表是构建当时（内存里 final 提取后）的数。**事后从 `route.db` 复核更保守**：
`top` +0.114 / +0.004 ns、`top_adc` +0.103 / +0.019 ns——`route.db` 是在
`update_timing -mode final` 之前导出的，重新导入再做一次 final 提取会多算一点延时。
两者都为正；引用时序时应以后者为准，方法与后仿真结果见
[`docs/timing-postsim-20261026.md`](docs/timing-postsim-20261026.md)。

资源（`top`）：LUT 13660 / 19600（69.69%）、REG 7325 / 19600（37.37%）、BRAM 46 / 64（71.88%）。
最紧的仍是 `sd_card_clk`（100 MHz）里的 BMP 读取块；音频域是 `u_audio_pll` 的 clk2
（12.295 MHz，周期 81.3 ns），余量 67 ns 以上，心跳、2:1 mux 和两级同步器都不在关键路径上。

### 2026-10-26 的一轮时序优化（BMP 读模块的 .ce 树）

**病灶**：`vendor/SD/bmp_read_scaled.v` 的失败判定 `fail_operation` 直接做为主状态机
`else if` 分支的条件，于是它必然出现在本模块几乎每个寄存器的 `.ce` 项里。它的一项
`wait_expired` 是 `idle_wait >= WAIT_TIMEOUT_CYCLES-1` 的 32 位比较，映射成 16 级进位链。
TD 报的前 10 条建立路径**全部**从 `idle_wait_reg[1]` 出发、终点是各个 `xxx_reg.ce`
（SWNS 0.123 ns，数据路径 9.597 ns 里 6.668 ns 是布线）。

**改法**：`fail_operation` 打一拍成 `fail_q` 再进状态机；出错原因当拍锁存到 `fail_cause_q`
（`error_code` 用锁存值，否则一拍后 `sd_sec_read_error_q` / `bad_sector` 已撤销会把编码判错）。
`bmp_data_wr_en` 仍用组合版——写侧不能再晚。错误响应晚 1 个 100 MHz 周期，对外不可见：
`abort_sd` 是电平，`load_error` / `scan_done` 是持久标志。

**结果**：SWNS 0.123 → **0.188 ns**（+53%），最差路径换成 `bmp_blur_background` 内部
一批 0.19~0.45 ns 的路径。

**天花板在哪**：布局阶段 SWNS 有 2.25 ns，布线完只剩 0.19 ns——2 ns 是布线吃掉的。
线长 1.43 M，slice 占用 82%（LUT 70%，但装包率只有 85%，碎片化严重）。
这个占用率下调布局/布线参数，结果只在 ±0.3 ns 噪声里来回。下面每一项都单独跑过完整 P&R：

| 试过的 | 结果 |
|---|---|
| `place max_fanout 32` | slice 82%→86%，SWNS → +0.007 |
| `aggr_multi_iter on` + `macro_performance ram_crit_path` + `post_route_opt medium` + `postrt_opt_extra_round 4`（TD 失败提示里那套） | SWNS → −0.445 |
| CongestionHigh 的密度项（`target_density 0.6` / `opt_max_density 50` / `enable_congestion_recovery on` 等） | 布线器直接报不可布 |
| `route hold_margin 100` | 保持修复一步不做，HWNS → −0.020 |
| `route effort high` | 与不改逐位相同 |
| blur 的 `INIT_COMPARE` 拆两拍 | SWNS → −0.111（已回退） |
| 综合侧 `gate infer_fsm one_hot` | LUT −157、深层路径端点 −82%，WNS 不变（保留） |

**要再多留余量只能减面积**：`sd_card_bmp_m0` 一块就占 3578 LUT + 2117 REG，
其中 `bmp_blur_background` 1435 LUT + 13 BRAM + 6 DSP，且全部落在 100 MHz 域。

**hold 为什么只有 10 ps**：TD 的 `fix_hold` 只修负 slack，而每个保持检查都带它自带的
0.100 ns 默认不确定度（路径明细里写作 `Clock Uncertainty 0.100ns (default)`）。
修到"不为负"就收工，报告值自然停在十几皮秒。把这 0.1 ns 守卫换算回去，
真实保持余量约 0.11 ns。任何 RTL 改动都要重跑完整 P&R，只看综合结论不算数。

### 读时序结果

构建结束会打印一行结论：

```
CPR_BUILD_PASS top setup=0.115 hold=0.011      ← 构建和时序摘要检查完成，仍需运行verify_td.py审查告警与覆盖
CPR_BUILD_FAIL top: Timing failed: setup=-0.563 hold=0.003   ← 失败，非零退出
```

明细在 `project/build/<top>/`：

| 文件 | 内容 |
|---|---|
| `timing_status.rpt` | 全局setup/hold余量摘要，须结合约束覆盖和告警 |
| `timing_summary.rpt` | 各时钟域余量 + 最差路径（约 1.5 MB）|
| `timing_check.rpt` | 时钟与约束覆盖检查；不替代CDC协议审查 |
| `gate_area.rpt` | LUT / REG / IO 占用 |

```bash
# 过没过
cat project/build/top/timing_status.rpt

# 哪个时钟域最紧（SWNS 最小的一行就是瓶颈）
awk '/Name *Type *Rise/,/^$/' project/build/top/timing_summary.rpt | head -10

# 具体是哪条路径
grep -A6 "Max Paths" project/build/top/timing_summary.rpt | head -40
```

**时序门禁**：`build.tcl` 在 `bitgen` **之前**检查 SWNS/STNS/HWNS/HTNS，任一为负就 `error` 退出，**不生成位流**。因此磁盘上的 `.bit` 可能来自上一次成功的构建，用 `ls -la` 核对时间戳，不要把旧位流当成本次结果。

### 烧写位流

`burn` 按名字**在整个仓库里模糊匹配**，而 `DEMO/` 下有 37 个厂商例程，**不要用裸名字**：

```bash
burn -n project/build/top/top.bit    # 干跑，先核对解析出的路径和字节数
burn    project/build/top/top.bit    # 烧到 SRAM，掉电丢失，调试用
burn -f project/build/top/top.bit    # 烧到 FLASH，掉电保留，现场固化
```

`burn top.bit` 会解析到 `DEMO/DEMO/30_LCD_ATK/top/top_Runs/phy_1/top.bit`（厂商 LCD 例程），不是本工程的位流。

缓存和缩放的范围、数据流及本次验证结果见[四槽全缓存与加载时缩放](docs/image-cache-scaling.md)。

## 不同分辨率图片打包

媒体层仍按裸扇区读取，不能直接把普通 FAT32 文件复制到卡上。可以先用离线工具创建镜像文件，再按原有安全流程把镜像写入整张卡：

```bash
python3 project/tools/pack_bmp_images.py \
  image_0.bmp image_1.bmp image_2.bmp image_3.bmp \
  --output card.img
```

工具只创建新的 `card.img`，不会打开或写入块设备。它检查正高度、24位、无压缩 BMP，限制宽≤2048、高≤1536，并按512字节对齐四张图片。写卡前仍需确认目标是已卸载的整盘；不要把工具输出直接写到正在使用的分区。

### 一条命令换教程图：`tfburn`

仓库根的 `tfburn` 把上面的"打包 + 写卡"合在一起，**只写图片区、不碰音频区**：

```bash
tfburn -n 暂存/教程图_20261027_merged/bmp_training_safe   # 干跑：校验、打包、打印要写哪些扇区
tfburn    暂存/教程图_20261027_merged/bmp_training_safe   # 真写（会要求输入 yes 确认）
tfburn -d                                                 # 只列出当前的卡，不动它
tfburn -D /dev/sdb <文件夹>                                # 有多张卡时手工指定
```

文件夹里放**正好 4 张** `.bmp`（按文件名排序当第 1~4 页，要求 640×480/24 位/无压缩）。脚本调用 `pack_bmp_images.py` 打同一个包（与 `assets/tutorials/cpr-tutorials-training-safe.img` 逐字节相同），再用 `dd bs=512 count=7204 conv=notrunc` 只覆盖 **LBA 0..7203**——音频的五个首扇区（`PICTURE_1..4`/`FREE_SONG` = 12000/123000/250000/370000/500000，直接读自 `rtl/audio/wav_track_select.v`）在镜像结束后 4796 个扇区处，因此不会被覆盖；写完还会把五个音频首扇区重新读出来和写前快照比对。写完回读整段镜像比对 sha256。卡上首扇区若是 FAT 引导区（别人的 U 盘）会直接拒绝，需 `-f` 才写。

## 使用

训练面板保留档位数字，并显示对应文字：0 待测、1 过轻、2 正常、3 过重。ADC 路径仍显示未标定，触点路径仍显示演示输入；分档阈值和计数方式不变。

KEY1 复位；KEY4 在教学、自动展播、训练之间循环；KEY2 在教学模式下一张、自动模式暂停/继续、默认训练模式按下并释放模拟按压；KEY3 上一张。默认按压档由 SW1～SW4 选择，0000 代用目标档，0001 浅、0011/0111 目标、1111 深。训练频率以完成释放事件间隔计量。

ADC 模式使用 CH4（M12，J2 第35脚），复用约12.295 MHz音频PLL；CH2（L10）与面板K2复用，不得使能。按压盒采用3.3V—3.3kΩ—节点—FSR—GND分压，当前参数为baseline=2900、触发250、释放120、目标带1600～2400。参数来自既有按压盒联调记录；FSR在大载荷下会饱和，档位仅反映压力幅度，不换算为厘米。界面保留未标定提示，KEY2在ADC模式不产生模拟按压。

有外部按键时，`top` 的 `USE_EXTERNAL_IO=1` 可选择五按键及四接触输入，具体见 pin.adc 和原 PR 输入契约。默认板载模式尚无亮度/独立清场按键。图片支持范围见上文；扫描依旧是受控原始扇区布局，不解析 FAT32 目录。不支持的格式或文件长度不足的 BMP 不会发布为有效图片。

帧发布流程与复位契约见 [frame-buffer-contract.md](docs/frame-buffer-contract.md)。必须等读端在帧边界确认新缓冲区后，才释放旧缓冲区；不再仅凭写完认为切图已经完成。

## 已知限制

SD/HDMI 的离线预算、正常传输 SPI 调整为约16.667 MHz的原因及复现方法，见[接口时序预算](docs/io-timing-budget.md)。板级电气签核与新位流上板结果单独记录。

缩放缓存专项仿真覆盖 640×480 逐像素直通、任意宽高比例、非4字节对齐行、BMP像素偏移跨扇区、SDRAM写 FIFO 满时停顿和四槽并发显示读。数字测试、完整构建和静态时序通过不等于实际显示/ADC/机械已通过。加密 SDRAM 刷新时的请求行为、长时间读写、板级 I/O 和 HDMI 接收端仍需上板验收。TD 可能报告内置 SDRAM 宏在中间 ECO 布局重新定位；当前验证脚本会保留并拒绝所有错误或严重告警，route/bitgen 成功不自动豁免该诊断。

本次结果见 [integration-verification.md](docs/integration-verification.md)。位流、日志及工具不进 Git。
