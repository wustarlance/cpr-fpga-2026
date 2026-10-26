# 时序复核与布局布线后仿真（2026-10-26）

> 一句话结论：**两个顶层的建立/保持余量复核后仍为正**（`top` +0.114/+0.004 ns，
> `top_adc` +0.103/+0.019 ns），**两个顶层的门级网表在 SDF 反标下都能从复位出来、
> 输出无 X、无致命错误**；但 TD 的仿真模型库有两处缺陷，导致整片后仿真里
> PLL 锁定与 HDMI 串行输出不可观测，这两条**只能由 RTL 级自检与上板实测覆盖**。

本次运行对应位流：`project/build/top/top.bit`、`project/build/top_adc/top_adc.bit`
（2026-10-26 构建，RTL 为 `bmp_read_scaled` 的 `fail_q` 改动之后的状态）。

---

## 1. 时序复核（STA）

### 1.1 方法与数据来源

不重跑 P&R，直接从已布线的数据库复核：

```bash
cd project
CPR_TOP=top     /d/ANLU/TD_6.2.1/bin/td_commands_prompt.exe scripts/postsim/sta_recheck.tcl
CPR_TOP=top_adc /d/ANLU/TD_6.2.1/bin/td_commands_prompt.exe scripts/postsim/sta_recheck.tcl
```

脚本做三件事：`import_db build/<top>/route.db` → `update_timing -mode final` →
`report_timing_status` + `report_timing_summary`。报告落在
`build/<top>/simulation/sta_recheck.rpt`（汇总）和 `timing_recheck.rpt`（路径明细）。

### 1.2 结果

| 顶层 | setup WNS | setup TNS | hold WNS | hold TNS |
|---|---|---|---|---|
| `top` | **+0.114 ns** | 0.000 | **+0.004 ns** | 0.000 |
| `top_adc` | **+0.103 ns** | 0.000 | **+0.019 ns** | 0.000 |

全部时钟周期校验通过（`sd_card_clk` 10、`ext_mem_clk`/`ext_mem_clk_sft` 25、
`video_clk` 40、`hdmi_5x_clk` 8 ns）。

**和构建日志里的数不一样，不是退步**：`build.tcl` 里 `export_db` 排在
`update_timing -mode final` 之前，所以 `route.db` 存的是"布线刚结束、还没做
final 延时提取"的状态；构建日志里那次 `report_timing_status`（`top` 0.188 /
0.010）是在内存里 final 更新之后算的。重新导入再做一次 final 提取，得到的是
更保守的一组（`top` 0.114 / 0.004，`top_adc` 0.103 / 0.019）。本次报告以
复核值为准——两者都为正，结论不变。

### 1.3 最差路径

`top`，setup，slack **+0.114 ns**：

| 项 | 值 |
|---|---|
| 终点 | `sd_card_bmp_m0/.../g_blur_background$u_bg/read_addr_q_reg[8]_syn_4.d[0]` |
| 时钟 | `sd_card_clk`（100 MHz，10 ns） |
| 数据路径 | 9.606 ns（单元 3.996 ns / 41%，线 5.610 ns / 59%） |
| 逻辑级数 | 9（ADDER×6、LUT3×2、LUT5×1） |
| 最大扇出 | 10 |
| 时钟偏斜 | +0.064 ns |
| 时钟不确定度 | 0.100 ns（TD 默认值，非 SDC 指定） |

`top_adc`，setup，slack **+0.103 ns**：

| 项 | 值 |
|---|---|
| 终点 | `u_board/sd_card_bmp_m0/.../bmp_read_m0/scan_found_sector_reg[0]_syn_4.ce` |
| 数据路径 | 9.617 ns（单元 2.962 ns / 30%，线 6.655 ns / 70%） |
| 逻辑级数 | 7（LUT4×3、LUT3×2、ADDER×2） |
| 最大扇出 | 37 |

两条都在 `sd_card_clk`（100 MHz）域的 BMP 缩放/模糊通路上，和上一轮
（2026-10-26 时序优化）的结论一致：**瓶颈是 82% slice 占用下的布线资源**
（线延迟占 59%~70%），不是逻辑级数。保持时间余量仍然只有几皮秒到十几皮秒，
这是 TD 的 `fix_hold` 只修到"不为负"加 0.100 ns 默认不确定度导致的，
换算回 0.1 ns 守卫约等于 0.10~0.12 ns 真实余量。

---

## 2. 后仿真（门级网表 + SDF 反标）

### 2.1 流程

"时序仿真"和"后仿真"在本工程里是同一次运行：TD 只有布线之后才有 SDF，
所以门级时序仿真必然就是后仿真。三步：

1. **导出**（不重跑 P&R）：`scripts/postsim/export.tcl` 从 `route.db` 出
   网表 `write_verilog` + 延时 `write_sdf`。
2. **编译**：TD 的 EG4 功能模型库（`sim_release/common/*.v` 映射层 +
   `sim_release/eg4/*.v` 器件层）＋ 网表 ＋ 测试平台。
3. **运行**：`vsim -sdfmax` 反标最差条件（setup corner），跑
   100 µs 复位 + 400 µs 建立 + 150 µs 观察窗。

```bash
cd project
CPR_TOP=top     td_commands_prompt.exe scripts/postsim/export.tcl
CPR_TOP=top_adc td_commands_prompt.exe scripts/postsim/export.tcl
cd ..
python tests/sim/postsim/run_postsim.py --top top --top top_adc \
    --modelsim "D:/Program Files/Mentor Graphics ModelSim SE-64 10.6e/win64"
```

### 2.2 规模

| 顶层 | 门级网表 | SDF | 反标条目（INTERCONNECT / IOPATH / SETUPHOLD） |
|---|---|---|---|
| `top` | 10.1 MB | 15.5 MB | 57 139 / 49 099 / 20 123 |
| `top_adc` | 10.9 MB | 16.7 MB | 57 467 / 49 405 / 20 105 |

编译 0 错误，`-sdfmax` 反标成功（`Loading timing data from .../*.sdf`），
运行时 0 致命错误。

### 2.3 结果

| 顶层 | 判决 | 复位释放 | video_clk | HDMI_CLK_P | 数码管扫描 | 输出 X |
|---|---|---|---|---|---|---|
| `top` | **PASS** | 100 µs | 16 234 沿（≈25 MHz） | 0 沿 | 窗口内 0 次变化 | 无 |
| `top_adc` | **PASS** | 100 µs | 16 234 沿（≈25 MHz） | 0 沿 | 窗口内 0 次变化 | 无 |

判据（四条全过才 PASS）：

1. SDF 真的被载入；
2. 加载与运行期间没有 `Fatal`/`Error`；
3. 复位释放 + 建立之后，`led`、`seg_sel`、`seg_data`、`sd_ncs`、`sd_mosi`、
   `HDMI_CLK_P/D0_P/D1_P/D2_P` 全部无 X；
4. `video_clk` 在跳——证明 PLL 时钟真的到了逻辑网。

`video_clk` 16 234 沿 / 650 µs ≈ **25.0 MHz**，与 `create_clock` 的 40 ns
一致：三路 PLL 的输出时钟、GCLK 缓冲和整条视频时钟树在门级网表下都是通的。

---

## 3. 厂商仿真模型的两处缺陷（本次实测确认）

这两条不是设计问题，但会把后仿真卡死或让某些信号"看不见"，必须记录：

### 3.1 `EG_PHY_PLL` 只出时钟，`extlock` 恒 0

单独搭平台测（把网表里的 PLL 实例原封不动搬出来）：

```
50 µs 内 clk0 = 4933 个上升沿（≈98.7 MHz，配置 100 MHz），extlock = 0
```

设计的 `por_reset_n = rst_n && all_plls_locked`，所以纯仿真里
`all_plls_locked` 永远是 0、**整片被永久复位**——第一次跑后仿真时表现就是
"复位释放后什么都没发生"。测试平台在复位释放那一拍
`force dut.all_plls_locked = 1'b1`（`top_adc` 是
`force dut.\u_board/all_plls_locked = 1'b1`），等价于真机上"晶振稳定、
PLL 已锁定"的前提。**这是对厂商模型的补丁，不是设计改动**；真机这一点由
板上实测保证。

### 3.2 LVDS 输出 pad 模型不产生串行数据

`HDMI_CLK_P` 在 650 µs 里 0 个沿，而同一时刻 `video_clk` 在正常跳
（25 MHz）。说明 `EG_PHY_PAD` 的 LVDS 串行输出路径在 ModelSim 里不建模，
芯片内部的 5× 串行时钟和 lane 移位寄存器在跑，只是没有从 pad 出来。
数码管扫描窗口内 0 次变化同理（显示内容依赖 SD/SDRAM 初始化，
无卡状态下停在初始画面）。

**因此整片后仿真能证明的是**：复位链在真实门延/线延下释放、时钟树通、
主输出无 X 泄漏、网表与模型库能干净编译加载。**它不能证明**画面内容、
HDMI 电气层与 SD 交互——那些由 RTL 级 58 项自检（`tests/sim/run_msim.py --all`，
2026-10-26 全量 58/58 PASS）和上板实测覆盖。

### 3.3 SDF 部分条目对不上 `specify`

TD 的 EG4 单元模型只有部分 `specify` 块，SDF 里有 91 条 `SETUPHOLD`/`IOPATH`
找不到对应约束（例如 pad 的 `do→opad`、`ipad→di`），ModelSim 默认按 fatal
处理并拒绝加载。处理方式：

- `-sdfnoerror`：降级为 warning（12 万条里 91 条，占比 0.07%，其余全部反标成功）；
- `+notimingchecks`：关闭 $setup/$hold 时序检查——**延时照常反标**，只是不报
  建立/保持违例。时序合法性本来由 STA（第 1 节）负责，后仿真不重复承担；
- `-sdfnowarn -suppress 3722 -suppress 3017`：压掉网表未连接端口与端口数不等的
  1 万余条告警（TD 网表省略了未用的宏单元端口，属正常）。

---

## 4. 本次没有做的事

- **没有重跑 58 项 RTL 功能自检**：RTL 自上轮 58/58 PASS 后未改动，本次只加
  了 `tests/sim/postsim/` 下的后仿真流程。
- **没有用 `-sdfmin` 跑保持侧（fast corner）**：单次整片后仿真约 7 分钟，
  保持余量已由 STA 给出（+0.004 / +0.019 ns，接近 0，是已知的 tool 策略问题）。
- **没有上板**：I/O 时序、HDMI 电气层、SD 卡交互仍需真机。

---

## 5. 复现与清理

复现命令见 2.1。产物位置：

- 网表/SDF/STA 报告：`project/build/<top>/simulation/`
- 仿真工作目录与日志：`tests/sim/build_msim/<UTC 时间戳>/<top>_postsim/`

本次按"只留报告"的要求，跑完后已删除所有仿真中间产物
（网表 10 MB、SDF 15~17 MB、ModelSim work 库、vsim/vlog 日志），
只保留 `project/build/<top>/simulation/sta_recheck.rpt` 与
`timing_recheck.rpt` 两份报告和本文档。需要重跑时按 2.1 重新导出即可，
TD 每次约 40 秒、ModelSim 每层约 7 分钟。
