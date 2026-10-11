# PR #1 与本地架构整合验证（2026-10-11）

以 PR `50fea941512f3aabfafb93ad200f84abf84bd79b` 为基础，保留其提交历史和应用模块，合入本地 SDRAM 40 MHz、刷新公式、BMP 扫描流水化。主工程采用 `project/project.al` 和 `rtl/ip/vendor/constraints` 分层，SD/BMP/帧缓存活动源码统一到 `vendor/SD`。

新增帧发布握手：图片源与写端均完成后，在读端帧边界锁存新地址，并将确认返回 SD 域；等待确认期间不复用旧缓冲。共同原始复位与异域上电就绪分离，就绪经两级同步和两级释放链。没有为 SDRAM 添加 false-path、多周期或异步分组；像素/串行钟保持相关。

## 数字功能

`python3 tests/sim/run.py --all --self-test-runner`：**17 项测试通过、5 项运行器控制达到预期**。保留原PR的11项，加 BMP扫描/加载、刷新公式、真实读FSM与发布握手、连续翻页缓冲所有权、OSD快照和复位。

证据目录：`tests/sim/build/20261011T050049.016925Z/`。源文件/工具/可执行产物哈希及日志由运行器保存；这些目录是本次本地结果，不进入 Git。

## TD 完整构建

使用 TD **6.2.178840**（6.2.1 SP1），执行：

```bash
python3 project/verify_td.py --td /usr/local/bin/td --stage full
```

证据目录：`project/build/verify_20261011T050816.364337Z/`，结果 `passed`，两个顶层均退出0，构建期间全部输入哈希保持一致。project.al 的 Path 随后恢复为可移植的 `.`；仅该元数据修改，顶层源码与约束未变。另重跑可移植路径综合通过。

| 顶层 | LUT | 寄存器 | BRAM9K | PLL | ADC | Setup WNS | Hold WNS |
|---|---:|---:|---:|---:|---:|---:|---:|
| top | 5658 / 19600 | 4237 | 20 | 3 | 0 | +0.213 ns | +0.014 ns |
| top_adc | 5900 / 19600 | 4377 | 20 | 3 | 1 | +0.149 ns | +0.003 ns |

两种顶层 TNS 均0，SDRAM两路实际周期25ns，SD卡10ns、像素40ns、HDMI串行8ns。ADC完整字约束命中源保持/目标捕获各12位。当前setup余量较小，后续RTL或约束修改必须重跑，不保证任意布局都产生同样数字。

`td rebuild.tcl` 另按 GUI 标准 `syn_1 → phy_1` 跑默认顶层：setup +0.213ns、hold +0.014ns，更新 `project_Runs/best_result`。ADC专用约束仍由 `CPR_TOP=top_adc` 脚本加载。

新位流：`project/build/top/top.bit` 与 `project/build/top_adc/top_adc.bit`。文件在本地保留但不提交 Git。

## 告警与边界

保留参考IP普通位宽/未驱动/初始化告警。TD在中间ECO布局报告内置 `U3/sdram` 位置移动的 `PHY-7002`；产品pin.adc没有该实例LOC绑定，完整route/DRC/bitgen完成。验证运行器只将这个精确诊断单独记录，不接受其它严重告警、路径空集合、无效约束或编译错误。

数字仿真和当前SDC覆盖路径的setup/hold通过，不等于模拟ADC精度、PLL锁定、电气接口或实际SDRAM功能已验收。没有下载板卡、擦写Flash或TF卡。仍需上板验证4图、模式/按键、音频、长时间刷新保持、连续切图和真实ADC。

FSR阈值仍为未标定压力码，不标作厘米。训练频率按完整释放事件间隔，语音、音乐、FAT32、转场、缩放、频谱等仍未实现。
