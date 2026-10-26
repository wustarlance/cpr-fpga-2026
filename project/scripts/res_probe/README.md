# res_probe —— 正弦查表方案的资源/精度探针

用来回答"把 64 点表换成 256 点表、或加插值乘法器，到底多花多少资源"。
不碰主工程：这里有一个独立的最小 TD 工程（`romtest.al`，只包含 `rom_variants.v`），
每个变体都是同一个外壳（`clk / ph[23:0] / amp[15:0] -> out[23:0]`），
所以测出来的差值就是"表 + 插值"本身的增量。

## 怎么跑

```bash
cd project/scripts/res_probe
CPR_VAR=v_rom64 /d/ANLU/TD_6.2.1/bin/td_commands_prompt.exe syn_one.tcl
# 结果看 qor_<variant>.qor 的 Utilization 段（#luts / #DSPs / #RAMs）

# 换工程（默认 romtest.al，里面是 rom_variants.v）：
CPR_VAR=hb_probe CPR_AL=hbprobe.al /d/ANLU/TD_6.2.1/bin/td_commands_prompt.exe syn_one.tcl
```

只做综合到 gate（不布局布线），一次约 10 秒。

## 实测结果（EG4S20BG256，TD 6.2.1，gate 级）

| 变体 | 方案 | LUT | DSP | BRAM | ΔLUT | 峰值误差 |
|---|---|---|---|---|---|---|
| `v_rom64`   | 64 点裸表（**当前实现**） | 39 | 1 | 0 | — | 3212 LSB / −20.2 dBFS |
| `v_rom256`  | 256 点裸表 | 91 | 1 | 0 | +52 | 804 LSB / −32.2 dBFS |
| `v_romqw`   | 1/4 表 65 项 + 象限折叠（等效 256 点） | 56 | 1 | 0 | +17 | 804 LSB / −32.2 dBFS |
| `v_rom64i`  | 64 点 + 线性插值 | 73 | 2 | 0 | +34 | 41 LSB / −58.2 dBFS |
| `v_romqwi`  | 折叠 + 插值（等效 1024 点） | 115 | 2 | 0 | +76 | 4 LSB / −79.0 dBFS |

误差是 75 Hz、48 kHz 下与理想正弦逐样本比的最大绝对误差（`sine_err.py` 的方法，
本目录未附脚本，见会话记录）。

## 结论

- 裸表误差 ∝ 1/N，插值误差 ∝ 1/N²。所以 **256 点表 +52 LUT 只买 12 dB，而插值 +34 LUT 买 38 dB**。
- 只想小幅改善：1/4 表折叠，+17 LUT，几乎免费，拿走全部 12 dB。
- 想真正干净：64 点 + 插值，+34 LUT +1 DSP，−58 dB。
- 让 TD 把它们推断成 BRAM 不划算：多 1 拍读延迟，`S_sin` 就不能再组合喂乘法器，要改流水线。

器件余量（2026-10-25 版布完）：slice 8090/9800 = 82.55%，剩 1710；BRAM 46/64；DSP 11。
音频 MCLK 域（clk3，81.3 ns）setup 余量 66.3 ns，加 1~2 级 LUT 无影响；
但全局 hold 余量只有 11~24 ps，任何改动都要重跑完整构建确认。

## 附：`heartbeat_synth` 退出收尾的代价（2026-10-26 增）

同一个探针外壳也用来量"心跳发声中途退出 I_enable 时的收尾"花了多少资源：

| 文件 / 顶层 | 方案 | LUT | 寄存器 | DSP |
|---|---|---|---|---|
| `hb_old.v` / `hb_old` | 立刻归零（改造前） | 144 | 75 | 1 |
| `hb_probe.v` / `hb_probe` | 包络收尾 + `O_busy`（现版本） | **161** | 75 | 1 |

结论：**+17 LUT、0 寄存器、0 DSP**（多出来的是一个 16 bit 减法器和"压到 0"的比较器，
`S_active` 复用，没有新增状态）。跑法：

```bash
CPR_VAR=hb_old   CPR_AL=hbold.al   .../td_commands_prompt.exe syn_one.tcl
CPR_VAR=hb_probe CPR_AL=hbprobe.al .../td_commands_prompt.exe syn_one.tcl
```

`hb_probe.v` / `hb_old.v` 是 RTL 的**改名牌副本**（`module hb_probe` / `hb_old`），
只为单独综合；改 RTL 后要重新拷一份，否则数字会过期。
