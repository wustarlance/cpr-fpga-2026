# 例程 5：SDRAM 40 MHz 验证版

2026-10-10 已把 `project/` 的 SDRAM 时序修复同步到本例程，并用 TD 6.2.1 SP1 完整重新构建。

## 修改与构建结果

- 两路 SDRAM 时钟：125 MHz → 40 MHz，保持 180° 相位；SD 卡逻辑仍为 100 MHz，像素钟仍为 25 MHz。
- 修正刷新宏的括号与计数终值；每 1171 拍（29.275 us）请求刷新。
- 相移钟命名为 `ext_mem_clk_sft`，仍分析 SDRAM 双向路径，没有新增 false-path 或多周期例外。
- 工程中补齐系统/视频 PLL、读/写 FIFO 的四个 `.ipc` 登记。
- BMP 扫描的文件长度舍入、下一扇区加法、边界判断拆成三拍，消除 GUI 重建时出现的 −0.006 ns 同域违例。
- 使用 GUI 相同的 `syn_1 → phy_1` 标准流程重新构建：`Setup WNS = +1.246 ns`、`Hold WNS = +0.003 ns`，TNS 均为 0。

扫描每扇区多三拍（100 MHz 下为 30 ns）；BMP 加载和 BGR 像素拼接未改变。此前发现的视频 AXIS 行结束和双缓冲问题尚未在此版本处理。

## 下载文件

新位流：

```text
src/td_project/build/lab_ex5_sdram40.bit
```

在 BitWriter 中选择 `PROGRAM_SRAM`，点 Add 添加上面这个文件，选中后 Run。本次已通过 `save_best_bits` 更新 `*_Runs/best_result` 位流，两处内容一致。

若 TD 已打开该工程，关闭后重新打开 `src/td_project/HDMI1.4b_Transmitter_v1.0.al`，让它重新读取新的 IP 登记和源文件。

## 连接与观察

- 四张与原例程相同的 640×480、24 位未压缩 BMP，TF 卡插入板卡。
- HDMI 线接 **HDMI_B**；显示设备打开 HDMI 音量。
- KEY1：复位；KEY2：下一张；KEY4：自动轮播开关。
- SW6 拨上可观察数码管状态。

观察首图是否出现、四图能否切换、是否有测试音，再连续轮播 10～30 分钟，检查花屏、斑点、黑屏或卡死；重复复位并测试加载期间按下一张。

若异常，记录数码管状态、是否有声音、是否每次复位都出现，以及原位流在相同素材和接线下是否正常。当前静态时序通过，真实 SDRAM 刷新和持续显示仍需这次硬件测试确认。

## 重新构建

```bash
cd /home/starlance/FPGA_Contest/05_lab_ex/lab_ex5_i2s/src/td_project
td rebuild_sdram40.tcl
```

此脚本重跑标准工程任务并检查最终 setup/hold，通过后更新 `best_result` 及验证位流。报告位于 `build/gui_timing_status.rpt`、`build/gui_timing_summary.rpt` 和 `build/gui_timing_check.rpt`。脚本末尾会退出 TD，应在终端运行。

`build_sdram40.tcl` 仍可作为独立 CLI 流程使用；它的布局结果可能与 GUI 不同，不能用它的一次结果代替标准运行验证。

扫描功能回归从仓库根目录执行 `bash tests/sim/check_bmp_scan.sh`，覆盖无图/格式不匹配、文件长度向上取整、扫描范围与目标数量，以及跨扇区像素加载。

第一次修改前的源码与工程文件备份在仓库 `.scratch/lab_ex5-before-sdram40-1oq__tir/`。本轮 −0.006 ns 的报告及位流另外备份在 `.scratch/bmp-scan-timing-before-c12xzwzf/`。
