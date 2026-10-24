> 2026-10-24：完成 [SD/HDMI 离线时序预算与自检](docs/io-timing-budget.md)，SD 正常传输改为约 16.67 MHz；现有 TD 6.2.168116 完整生成两顶层位流、内部 setup/hold 为正。6 项 RTL、27 项 Python 检查通过，2 项故障注入按预期失败。严格检查仍 failed、板级 I/O 为 conditional；未上板，下方历史通过记录不替代本次结果。
>
> 2026-10-23：TD 6.2.168116 已完成两个顶层的新一轮布局布线，修复页面/ADC邮箱的SDC回放绑定，并增加约束覆盖门禁；严重告警和接口审查仍未完成，严格验收为failed。见[本轮TD验收记录](docs/td-acceptance-20261023.md)。
>
> D123白线修正、按键映射及两轮SRAM观察见[白线修正说明](docs/white-lines-20261023.md)。本轮TD候选未下载上板，未写Flash。

> 本地修复版（2026-10-17）：频率与刷新互锁改动见 [修复说明](docs/display-fixes-20261017.md)。41 项 RTL 及 5 项运行器检查通过；本次尚未完成 SP1 布局布线及实板复验。下方构建状态属于修复前的主分支基线。

> **当前状态（2026-10-18）**：44 项 RTL 自检与 5 项运行器控制全部通过；TD 完整构建两个顶层均通过，零违例端点（`top` SWNS **+0.116 ns**、`top_adc` **+0.104 ns**），位流已生成，可上板。PR #3/#4、四槽全缓存、加载时缩放、模糊补边、中文界面与音频节拍器均已合入当前工作区。
>
> 下方按日期排列的小节是各次接入时的历史记录，其中的自检数量（23/27/30/39 项）反映当时版本，**不代表当前状态**。当前数量以本节为准。

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

音频内容由 `rtl/cpr_audio_tone_i2s.v` 产生，48 kHz、24 bit、方波：教学浏览与自动展播播放 do-re-mi 音阶（每音 0.5 s 循环）；按压训练锁定 **A4 440 Hz**，每次节拍提示响 40 ms 后静音，使各拍音高一致。`I_metronome` 来自 25 MHz 视频域，模块内两级同步，首级在 `constraints/audio_metronome.sdc` 中豁免。声音只经 HDMI 输出，板上没有蜂鸣器。

本工程整合 PR #1 的训练、ADC、OSD、复位和自检，与本地 SDRAM 40 MHz、刷新参数及 BMP 扫描流水化修复。媒体层继续用原始扇区扫描。当前 BMP 路径支持正高度、24 位无压缩、宽≤2048/高≤1536 的图片，加载时最近邻等比缩放并居中。需要补边的图片在加载阶段额外读取一遍源图，生成 32×24 cover 裁切背景，经区域均值降采样、三遍3×3盒式模糊、双线性放大并保留75%亮度，再盖上清晰前景写入 SDRAM；无补边图片仍走原来的单遍缩放。前四张会预载入四个固定 SDRAM 槽位，四槽就绪后手动/自动切换不再访问 SD 卡或重新计算模糊背景。设置顶层参数 `BLUR_BACKGROUND=0` 可恢复固定深蓝灰补边并取消双遍加载。

尚未实现：FAT32 目录与碎片文件、top-down/压缩 BMP、语音或音乐播放、频谱可视化、转场特效。前景仍使用最近邻采样；补边背景已在 RTL 中实现区域均值、三遍盒式模糊、双线性放大和亮度压暗。ADC 数字链可构建，模拟输入与机械深度仍未标定。

## 目录与依赖

- `rtl/`：应用、训练、ADC、OSD、帧发布逻辑。
- `ip/`：系统/视频 PLL 配置与配套 HDL；SD 时钟100 MHz、SDRAM 40 MHz/180°、像素25 MHz、串行125 MHz。
- `vendor/SD/`：主工程实际编译的 SD/BMP/帧缓存源码，包含分辨率适配、行填充、扫描分拍及读端切换边界。
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

`td` 指 `/usr/local/bin/td`（指向 TD 6.2.1 SP1 的启动器），不要用 `bin/td`。

### 命令行构建的三种用法

```bash
cd project

CPR_TOP=top     td build.tcl   # 默认演示版：板载按键模拟按压。约 90 s
CPR_TOP=top_adc td build.tcl   # ADC 采集版：真实按压盒。约 146 s
CPR_TOP=top CPR_STAGE=synth td build.tcl   # 只综合不布局布线，约 55 s
```

`CPR_STAGE` 未设置时等于 `full`（综合→布局→布线→时序检查→生成位流）；`synth` 只跑到 `optimize_gate`，**不生成位流**，适合快速确认代码能否综合。

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

## 使用

KEY1 复位；KEY4 在教学、自动展播、训练之间循环；KEY2 在教学模式下一张、自动模式暂停/继续、默认训练模式按下并释放模拟按压；KEY3 上一张。默认按压档由 SW1～SW4 选择，0000 代用目标档，0001 浅、0011/0111 目标、1111 深。训练频率以完成释放事件间隔计量。

ADC 模式使用 CH1（M10，J1 第16脚），复用约12.295 MHz音频 PLL。当前归一化 baseline=3000，触发150、释放100、评级800～1600均为未标定压力码，OSD 显示 `PRESS UNCAL`。不能将它们直接解释为厘米。KEY2 在 ADC 模式不产生模拟按压。

有外部按键时，`top` 的 `USE_EXTERNAL_IO=1` 可选择五按键及四接触输入，具体见 pin.adc 和原 PR 输入契约。默认板载模式尚无亮度/独立清场按键。图片支持范围见上文；扫描依旧是受控原始扇区布局，不解析 FAT32 目录。不支持的格式或文件长度不足的 BMP 不会发布为有效图片。

帧发布流程与复位契约见 [frame-buffer-contract.md](docs/frame-buffer-contract.md)。必须等读端在帧边界确认新缓冲区后，才释放旧缓冲区；不再仅凭写完认为切图已经完成。

## 已知限制

SD/HDMI 的离线预算、正常传输 SPI 调整为约16.667 MHz的原因及复现方法，见[接口时序预算](docs/io-timing-budget.md)。板级电气签核与新位流上板结果单独记录。

缩放缓存专项仿真覆盖 640×480 逐像素直通、任意宽高比例、非4字节对齐行、BMP像素偏移跨扇区、SDRAM写 FIFO 满时停顿和四槽并发显示读。数字测试、完整构建和静态时序通过不等于实际显示/ADC/机械已通过。加密 SDRAM 刷新时的请求行为、长时间读写、板级 I/O 和 HDMI 接收端仍需上板验收。TD 可能报告内置 SDRAM 宏在中间 ECO 布局重新定位；当前验证脚本会保留并拒绝所有错误或严重告警，route/bitgen 成功不自动豁免该诊断。

本次结果见 [integration-verification.md](docs/integration-verification.md)。位流、日志及工具不进 Git。
