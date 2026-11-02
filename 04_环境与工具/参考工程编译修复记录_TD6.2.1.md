# 参考工程在 TD 6.2.1 下的编译修复记录

> 日期：2026-09-18
> 起因：`lab_ex5_i2s` 在 TD 6.2.3 下报 4 个黑盒（`sys_pll` / `video_pll` / `wfifo_32_32_512` / `rfifo_32_32_512`），原以为是"IP 版本太旧、需要重新生成"，于是准备重做这 4 个 IP。
> 结果：**不需要重新生成 IP**。真正原因是 **6.2.3 往工程文件里写了三处 6.2.1 读不了的东西**。修复后 **综合 + 布局布线 + 位流全部跑通（0 错误，42 秒）**。
> ⚠️ 但**时序未达标**：`ext_mem_clk`(125 MHz) 建立时间 WNS **−6.301 ns**。见第四节。

---

## 〇、结论速览

| 项目 | 结果 |
|---|---|
| 黑盒原因 | ❌ 不是 IP 版本旧，也**不是文件缺失** —— 4 个模块的源码一直都在 `user_source/hdl_source/ip/` |
| 真正原因 | ✅ 6.2.3 改过的工程文件里有 **3 处** 6.2.1 不兼容：**XML 注释 / 版本号格式 / 丢失的 4 条源文件记录** |
| 修复方式 | 手改工程文件（`.al` + 两个运行副本 `.prj`），**不需要**重新生成 IP |
| 构建结果 | ✅ **成功**：`ERROR 0`，位流 629,624 字节，总耗时 42 秒（综合 13s + 物理实现 29s） |
| 时序结果 | 🔴 **未达标**：Setup WNS **−6.301 ns**，92 个违例端点；Hold 无违例 |
| 未做 | 未上板验证（等板卡）；未修复时序 |

---

## 一、病因：一个被误判的问题

### 1.1 先纠正原来的诊断

之前的判断是"`hdl_source/ip/` 下 4 个 IP 是 TD 5.6 生成的，6.2.3 打开工程时把它们丢了"。**结论对了一半，但方向错了**：

- 那 4 个 IP 的源码文件 **一直都在**，一个都没丢；
- 报"黑盒"是因为**它们没被列进工程的源文件清单**，而不是文件不存在；
- 而且它们的**文件名和里面的模块名不一致**，这也是误导来源：

| 黑盒报错的模块名 | 实际定义在哪个文件 |
|---|---|
| `sys_pll` | `ip/sys_pll.v` |
| `video_pll` | `ip/video_pll.v` |
| `wfifo_32_32_512` | **`ip/afifo_16_32_256.v`** ← 文件名对不上 |
| `rfifo_32_32_512` | **`ip/afifo_32_16_256.v`** ← 文件名对不上 |

- 那 4 个 `.v` 是**纯文本 IP 包装**（`sys_pll`/`video_pll` 只是实例化 `EG_PHY_PLL` + `EG_LOGIC_BUFG`，`afifo_*.v` 是 RTL 级异步 FIFO），原语都在 6.2.1 的 `arch/eagle_macro.v` 里；
- 文件头里的 `** TD version : 5.6.119222` **只是一行注释**，不是版本锁。

### 1.2 真正的三处不兼容

`ip/` 目录下 6 个文件在工程里**一条引用都没有**（工程共 35 条 `.v/.vhd` 引用，`ip/` 占 0 条）。

而修复过程中，6.2.1 依次报出三个错误，**每修掉一个才露出下一个**：

| 顺序 | 错误码 | 报错内容 | 病因 | 修法 |
|---|---|---|---|---|
| 1 | `HDL-8007` | `sys_pll is a black box` … | 4 条源文件记录被 6.2.3 升级丢弃 | 补 4 条 `<File>` 记录 |
| 2 | `PRJ-8641` | `Project file format error: XML tag <xmlcomment> is invalid` | 6.2.3 在工程文件第 2 行写了一条 XML 注释，**6.2.1 的工程解析器不认注释** | 删掉那行注释 |
| 3 | `PRJ-9024` | `Invalid building version 6.2.3.210850` | `<TD_Version>` 是 6.2.3 的构建号，不在 6.2.1 的**白名单表**里 | 改成 6.2.1 自己的写法 |

**第 3 条的坑最深**：我先试了 `<TD_Version>6.2.1.178840</TD_Version>`，**依然被拒**（`Invalid building version 6.2.1.178840`）。最后用 `create_project` 让 6.2.1 自己建了个工程，看它写什么，才拿到正确格式：

```xml
<TD_Version>6.2.178840</TD_Version>
```

注意是 **`6.2` + 构建号**，不是 `6.2.1` + 构建号 —— 对应横幅 `Tang Dynasty, V6.2.178840`。而且 6.2.1 生成的文件里**没有 XML 注释**，反过来印证了第 2 条。

> 复现脚本留在 `.tools/probe/`（用 6.2.1 建的空白工程 `probe1.al`），可以随时查证 6.2.1 期望的工程文件格式。

---

## 二、修复操作（已执行）

改动落在 **3 个文件**（都先做了备份）：

| 文件 | 补 4 条源文件 | 删注释 | 改版本号 | 备份文件 |
|---|---|---|---|---|
| `src/td_project/HDMI1.4b_Transmitter_v1.0.al` | ✅ | ✅ | ✅ | `.before-ipfix.bak` / `.before-versionfix.bak` |
| `…_Runs/syn_1/HDMI1.4b_Transmitter_v1.0.prj` | ✅ | ✅ | ✅ | `.prj.before-commentfix.bak` |
| `…_Runs/phy_1/HDMI1.4b_Transmitter_v1.0.prj` | （运行副本由 `.al` 重新生成） | ✅ | ✅ | `.prj.before-fix.bak` |

补进去的 4 条（`CompileOrder` 接在原有最大值 39 之后）：

```xml
<File Path="../user_source/hdl_source/ip/sys_pll.v">          <!-- → module sys_pll -->
<File Path="../user_source/hdl_source/ip/video_pll.v">        <!-- → module video_pll -->
<File Path="../user_source/hdl_source/ip/afifo_16_32_256.v">  <!-- → module wfifo_32_32_512 -->
<File Path="../user_source/hdl_source/ip/afifo_32_16_256.v">  <!-- → module rfifo_32_32_512 -->
```

> ⚠️ 这 4 个模块是"一个文件一个模块"，靠**内容**而不是文件名解析。以后看到 `afifo_16_32_256.v` 里写着 `module wfifo_32_32_512` 不要以为是笔误 —— 原作者就是这么组织的。

---

## 三、构建结果（✅ 成功）

用工程级流程跑完整链：

```tcl
# src/td_project/build_621.tcl
import_device eagle_s20.db -package EG4S20BG256
open_project HDMI1.4b_Transmitter_v1.0.al
reset_runs {syn_1 phy_1}
launch_runs {syn_1 phy_1} -jobs 2
wait_run syn_1 -quiet
wait_run phy_1 -quiet
save_best_bits
exit
```

```bash
cd src/td_project && /home/starlance/FPGA_Contest/.tools/td build_621.tcl
```

**结果：`ERROR 总数 0`，`PRJ-1410 : Run phy_1 success.`**

| 项目 | 值 |
|---|---|
| 工具版本 | `Running with : Tang Dynasty v6.2.178840` ✅ |
| 位流 | `…_Runs/phy_1/HDMI1.4b_Transmitter_v1.0.bit`，**629,624 字节** |
| 最佳结果 | `…_Runs/best_result/HDMI1.4b_Transmitter_v1.0.bit`（同上） |
| 耗时 | 综合 13 s + 物理实现 29 s = **42 s** |

**资源占用**（`phy.area`，EG4S20BG256）：

| 资源 | 用量 | 占比 |
|---|---|---|
| LUT | 4,103 / 19,600 | 20.93% |
| 寄存器 | 3,794 / 19,600 | 19.36% |
| BRAM | 20 / 64 | **31.25%** |
| PLL | 3 / 4 | 75% |
| IO | 28 / 188 | 14.89% |

对照之前对你们方案的资源估算：**这个参考工程只用了 21% LUT / 31% BSRAM**，说明"底图 + 双缓冲 + HDMI + SD + 音频"这套完整链路离器件上限还远，**余量足够叠加图层/字幕/OSD**（你们方案里担心的 BSRAM 瓶颈，在这个例程里并不紧张）。

### 诊断过程中留下的日志

`…_Runs/syn_1/` 下依次留下（**建议保留，是完整的排错链证据**）：

| 日志 | 对应阶段 |
|---|---|
| `rerun_621.log` | 补文件后 → 报 `HDL-8007` 黑盒（**证明补文件前确实是黑盒**） |
| `rerun_621b.log` | 删注释后 → 报 `PRJ-9024` 版本无效 |
| `rerun_621c.log` | 改 `6.2.1.178840` 后 → 仍报版本无效 |
| `rerun_621d.log` | 改成 `6.2.178840` 后 → ✅ **0 错误，综合通过** |

---

## 四、🔴 时序未达标（必须关注）

位流出来了，**但建立时间违例**：

```
Setup : WNS -6.301 ns   TNS -295.579 ns   违例端点 92 个
Hold  : WNS  0.003 ns   TNS    0.000 ns   无违例
STA coverage: 96.01%
```

**违例全部集中在 125 MHz 的存储器域**：

| 时钟 | 频率 | WNS | TNS | 违例端点 |
|---|---|---|---|---|
| **`ext_mem_clk`（SDRAM 接口）** | 125 MHz | **−6.301 ns** | −197.968 ns | 8 |
| `sys_pll` 第 3 路输出 | 125 MHz | −3.438 ns | −97.136 ns | 1 |
| `sd_card_clk`（TF 卡） | 100 MHz | −0.475 ns | −0.475 ns | 1 |
| `video_clk` | 25 MHz | +29.678 ns | 0 | 0 |
| `hdmi_5x_clk` | 125 MHz | +4.848 ns | 0 | 0 |
| `clk`（输入） | 50 MHz | +6.142 ns | 0 | 0 |
| `audio_mclk` | 12.295 MHz | +75.399 ns | 0 | 0 |

**约束本身是合理的**，不是约束写错：`timing.sdc` 用 `create_clock` 声明输入 50 MHz，再用 `derive_clocks` + `rename_clock` 把 PLL 的 4 路输出分别命名，STA 推出的频率（25 / 100 / 125 / 12.295 MHz）与设计意图一致。

**含义**：

- `ext_mem_clk` 上 −6.301 ns ≈ 关键路径要 **14.3 ns**，而 125 MHz 只给 **8 ns**。这条路径跑不到 125 MHz。
- 这是**SDRAM 读写通路**（`frame_read_write` 的写侧/读侧 + `sdram.v` 接口）。对你们项目直接相关：**参考工程的时序瓶颈就在 SDRAM 侧，不在视频侧**。
- 位流虽然生成了，但**不代表上板一定能稳定工作**。这类违例通常表现为偶发的花屏、卡帧，而不是彻底不亮 —— 属于最难查的那类问题。

### 4.1 🔬 根因已定位（2026-09-22 补充）

对 `phy_1/final_timing.rpt`（16202 行）做了完整提取，结论如下。

**① 负 slack 只出现在两个跨时钟组里**

| Path Group | WNS | 端点 | 说明 |
|---|---|---|---|
| **`sys_pll_m0/pll_inst.clkc[2]` → `ext_mem_clk`** | **−6.301 ns** | 32 | ☠️ **就是它**（STNS −197.968 ns） |
| `ext_mem_clk` → `sys_pll_m0/pll_inst.clkc[2]` | −3.438 ~ −3.180 ns | 若干 | 同一对时钟的反向 |
| `sd_card_clk` → `video_clk` | −0.475 ns | 1 | 跨域，属正常 CDC 范畴 |
| **`ext_mem_clk` → `ext_mem_clk`（同域）** | **+0.081 ns** | 0 | ✅ **同域内其实完全没问题** |

> ⚠️ **注意**：同域 `ext_mem_clk → ext_mem_clk` 的最差路径 slack 是 **+0.081 ns（正的）**，
> 所以"125 MHz 存储器域整体跑不动"这个印象是错的 —— **问题只在那一对时钟之间**。

**② `clkc[2]` 就是那路 180° 相移的 SDRAM 时钟，且 SDC 里确实漏了它**

`timing.sdc` 只 `rename_clock` 了三路 `sys_pll` 输出中的两路：

```tcl
rename_clock -name {sd_card_clk} ... [get_pins {sys_pll_m0/pll_inst.clkc[0]}]   # 100 MHz
rename_clock -name {ext_mem_clk} ... [get_pins {sys_pll_m0/pll_inst.clkc[1]}]   # 125 MHz
# ❌ clkc[2]（125 MHz @180°，fanout 1）没有 rename → 报告里以原始实例名出现
```

`clkc[2]` 的物理去向（从路径报告读出）：`sys_pll clkc[2]` → `U3/u2_ram/SDRAM_CLK` → **只驱动 SDRAM 时钟输出 PAD**（fanout 1）。

**③ ☠️ 推翻原假设：这条路径上「没有任何组合逻辑」**

```
Begin Point : U3/sdram.dq[0]        (由 clkc[2] 触发)
End Point   : U3/sdram_syn_1.bpad   (由 ext_mem_clk 触发，输入 PAD 寄存器)
Data Path Delay : 6.453ns  (cell 6.453ns (100%), net 0.000ns (0%))
Logic Level : 0        ← ★ 关键
Max Fanout  : 0
Budget      : 4.000ns { ext_mem_clk rising@8.000 - clkc[2] rising@4.000 }
```

`Logic Level: 0`、`cell 占比 100% / net 占比 0%` —— **这条路上一个 LUT 都没有**。
它纯粹是：**PLL → SDRAM 时钟输出 PAD → （外部 SDRAM 器件模型）→ 数据输入 PAD**。

> 🔴 **所以原文第 4 节"尚未做的分析"里的方向 1 是错的**：
> 「判断是 SDRAM 接口的**组合逻辑太长**」—— **没有组合逻辑可缩短，改 RTL 或换综合策略都不会有用。**
> 唯一可能有用的两个方向是：**约束建模**（`set_multicycle_path` / 相位关系）和**降频**。

**④ 真正的争议点：预算该是 4 ns 还是 12 ns**

| 量 | 值 | 说明 |
|---|---|---|
| 到达时间 | ~11.4 ns | = SDRAM_CLK 输出 PAD(3.418) + TD 对**外部 SDRAM** 的默认模型 `input (hard ip) 5.000ns` |
| TD 认为的预算 | **4.000 ns** | 因为它取 `clkc[2]`(4 ns 沿) 之后**最近**的一个 `ext_mem_clk` 沿(8 ns) |
| 若按"下一个周期捕获" | **12.000 ns** | 4 ns 沿 → 数据 9.4 ns 有效 → 取 16 ns 沿捕获，则预算 = 16 − 4 |

`ext_mem_clk_sft` 这路 **180° 相移时钟存在本身就是线索**：把送给 SDRAM 的时钟挪半拍，正是为了让回读数据对齐到 FPGA 内部的**下一个**上升沿。
若设计意图确实是"下一周期捕获"，则 TD 的 4 ns 预算**过于悲观**，需要加：

```tcl
# 方向（待验证后启用）：把这一对时钟的建立关系放宽一个周期
set_multicycle_path -setup 2 \
    -from [get_clocks {sys_pll_m0/pll_inst.clkc[2]}] \
    -to   [get_clocks {ext_mem_clk}]
set_multicycle_path -hold 1 \
    -from [get_clocks {sys_pll_m0/pll_inst.clkc[2]}] \
    -to   [get_clocks {ext_mem_clk}]
```

**⑤ 下一步（按优先级）**

1. 🔴 **查 `sdr_as_ram` IP 的文档/手册，确认回读数据是在 `ext_mem_clk` 的哪一拍被采样的。**
   这一条**能一次性判定 4 ns 还是 12 ns**，是整个问题的分水岭。
2. 若确认是"下一周期捕获" → 加上述 `set_multicycle_path`，重跑 STA 验证。
3. 若确认不是 → 说明 125 MHz 对这个 SDRAM 接口确实过紧，**降到 100 MHz**（8→10 ns，预算从 4 ns 变 5 ns，仍偏紧）或更低，并重核带宽。
4. 顺手把 `clkc[2]` 也 `rename_clock` 成 `ext_mem_clk_sft`，报告可读性会好很多。

> 📌 **对多图层路线决策的意义**：由于瓶颈是 **I/O 往返**而不是逻辑，**"再加一路 SDRAM 读通道"（走读第 4 站 B 方案）并不会加剧这条路径**——
> 它增加的是 SDRAM 的**带宽占用**，不是这条 I/O 路径的延迟。
> 所以 B 方案的真正约束是**带宽**，不是这 −6.3 ns。这个区分对路线选择很关键。

---

**尚未做的分析和动作**（下一步的方向）：

1. 提取违例最差路径的**起终点与逻辑级数**，判断是 SDRAM 接口的组合逻辑太长，还是约束过紧（例如 `ext_mem_clk` 是否需要 `set_multicycle_path`）。
2. 检查 `sys_pll` 第 3 路输出（fanout 1）用途 —— 它**没有在 `timing.sdc` 里被 `rename_clock`**，属于约束遗漏。
3. 考虑 SDRAM 域降频（例如 100 MHz）看是否仍满足带宽需求。按走读笔记的估算，640×480 双缓冲带宽需求约 147 MB/s，降频后需重新核。

---

## 五、⚠️ 操作失误记录：厂商原始位流被覆盖

`save_best_bits` 把新的实现结果覆盖到了 `…_Runs/best_result/`，**厂商原有的位流和它的时序报告（`_phy.ts`）被覆盖，且工作区不是 git 仓库、也没有原始压缩包，因此无法恢复**。

这是我的操作失误 —— 应该在跑 `save_best_bits` 之前先备份 `best_result/`。

**影响评估**：

| 损失 | 严重度 | 说明 |
|---|---|---|
| 厂商的 `.bit` | 🟢 低 | 位流是可再生产物，源码完好，随时能重建；而且新的这份是用**比赛要求的 6.2.1** 构建的，反而更可用 |
| 厂商的 `_phy.ts`（时序数据） | 🟡 中 | 本来可以用它对照"厂商那次是否也时序违例"，现在无法回答这个问题 |

**后续若还要重建/覆盖产物，先备份。**

---

## 六、对你们自己项目的三条启示

1. **工程文件不要跨 TD 版本互开。** 用 6.2.3 打开 6.2.1 的工程、再回到 6.2.1，会踩到本记录第二节的三个坑（XML 注释、版本号格式、源文件记录丢失）。你们全队统一用 6.2.1，从源头避开这件事；如果拿到别人用别的版本建的工程，先备份再开。
2. **IP 不要手写、也不要从别处抄 `.v`。** 这次的坑本质上源于"IP 文件在工程里没被登记"。你们自己的 PLL / 异步 FIFO / ROM / SDRAM 控制器，**一律用 6.2.1 的 IP Generator 生成并登记进工程**，不要复制粘贴。
3. **时序瓶颈先看 SDRAM 域（125 MHz），不是视频域（25 MHz）。** 视频侧有 29.678 ns 的余量，非常宽松；带宽和时序的压力都在 SDRAM 侧。你们方案的"底图 + 标注图层"若要再加一路 SDRAM 读通道（走读第 4 站的 B 方案），**必须先确认 125 MHz 时序能不能过** —— 现在这个参考工程本身就有 −6.3 ns 的违例，加负载只会更紧。**这直接影响多图层叠加该选哪条技术路线。**

---

## 七、待办

- [ ] 🔴 **分析并处理 `ext_mem_clk` 的 −6.301 ns 违例**（第四节列了 3 个方向）
- [ ] 检查 `sys_pll` 第 3 路输出（125 MHz，fanout 1）的用途，判断是否要在 `timing.sdc` 里补 `rename_clock`
- [ ] 上板验证（等板卡到货）：这份 6.2.1 位流能否正常显示图片 + 出声
- [ ] 把本记录第 6 节的三条启示并入方案文档（尤其第 3 条对多图层路线选择的影响）
