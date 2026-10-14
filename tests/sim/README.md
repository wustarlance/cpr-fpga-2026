# 仿真验证状态（2026-10-13）

默认清单为23项RTL自检；新增训练栅格对照、布局/帧快照与完整底图透出检查。默认每次编译/运行超时为120秒，以容纳约60秒的双实例画面扫描；运行器负控仍独立限时。见[训练底图修改说明](../../project/docs/training-layout.md)。

---

# RTL 功能仿真

`run.py` 的测试清单逐项指定 `project/rtl/` 产品模块及 TB，不会把只跑行为桩当作产品验证。需要 Python 3.9+ 和 Icarus Verilog；脚本只用 Python 标准库。

仓库根目录执行：

```sh
python tests/sim/run.py --all --self-test-runner
python tests/sim/run.py tb_adc_ctrl tb_peak_detect
python tests/sim/run.py --list
```

Windows PowerShell 可显式指定工具，路径有空格时加引号：

```powershell
python tests/sim/run.py --all --iverilog "C:/tools/iverilog/bin/iverilog.exe" --vvp "C:/tools/iverilog/bin/vvp.exe"
```

MSYS2 portable 目录需要 `ucrt64/bin` 中的运行库和 `ucrt64/lib/ivl` 中的编译后端/VPI。脚本把工具目录加入**子进程** PATH，并自动识别相邻的 `lib/ivl`；也可用 `--ivl-dir` 显式传入。不会修改系统环境变量。该工作区的工具若保存在 `work/iverilog-portable/ucrt64/`，脚本可自动找到。

Linux/macOS 或 Git Bash 可执行 `bash tests/sim/run.sh --all`。`run.sh tb_name wave` 仅在 TB 确实生成相应 VCD 且 GTKWave 已安装时打开波形。

## 产品测试清单

| 测试 | 主要检查 |
|---|---|
| `tb_adc_ctrl` | 快速/稀疏采样、PD 时序、EOC 接收、超时恢复、旧 EOC 与复位取消 |
| `tb_pressure_normalize` | 两种极性、码值边界、四点预热/取整、连续或间断 valid |
| `tb_peak_detect` | 阈值边界、追踪峰值、完整释放后一次事件、持压清场/停用 |
| `tb_sample_mailbox` | 双时钟完整字的顺序与单次传输、忙时丢样、共同复位 |
| `tb_cpr_sensor_path` | 实际采样链与双时钟 ADC 模型、滤波/按压、超时和溢出抑制 |
| `tb_training_events` | 事件计数、间隔两侧边界、同拍 tick/事件、故障及清场 |
| `tb_video_rgb_to_axis` | 两帧 640×480 的像素、SOF、每行第 640 像素 EOL 与复位 |
| `tb_training_core` | 接触式按压计数与节拍、持压进入或清场后必须重新释放 |
| `tb_cpr_control` | 三模式、按键去抖、浏览控制与训练接口集成 |
| `tb_rate_display_lut` | 频率显示有效区间和查表范围 |
| `tb_brightness_rgb` | RGB 亮度档位、边界和组合输出 |
| `tb_bmp_scan` | 格式过滤、扫描边界、文件长度取整、跨扇区像素加载 |
| `tb_sdram_refresh` | 刷新计数和实际周期满足保持期限 |
| `tb_frame_buffer_publish` | 真实读 FSM 在帧边界锁存地址后才确认、复位取消 |
| `tb_sd_buffer_ownership` | 连续翻页、源/写完成先后、等待切换时不复用旧缓冲 |
| `tb_cpr_overlay` | 帧内状态稳定、下一帧快照、数字饱和与评级颜色 |
| `tb_reset_release` | 异步置复位、就绪同步及同步释放 |
| `tb_contrast_rgb` | 三通道对比度逐值、负数取整、饱和及无像素延迟 |
| `tb_font5x7_rom` | 全部256字符地址与原字模期望表 |
| `tb_scroll_contract` | 参数边界、裁剪、帧计数、完整回绕、暂停/隐藏及字模联调 |
| `tb_contrast_controls` | 全部拨码映射、短脉冲过滤、训练保持与ADC模式实时调节 |
| `tb_cpr_overlay_features` | 教学透明区、字幕颜色、帧参数快照及展播暂停恢复 |
| `tb_training_layout` | 完整教程区域透出、面板/文字/标记/字幕边界、两种输入模式与告警帧 |

## 成功判据与证据

每项必须同时满足：编译返回 0；仿真在超时前返回 0；没有 `FAIL`、`FATAL`、`TIMEOUT`；出现清单要求的 `PASS` 文本；执行期间源文件未变。空 `$finish` 会失败。TB 用 `$fatal(1, ...)` 报错，默认每次编译和运行超时 120 秒，可用 `--timeout` 修改。

每次在 `tests/sim/build/<UTC 时间戳>/` 创建独立证据目录，保留编译/运行日志、命令、源文件 SHA256、工具版本与可执行文件 SHA256、编译产物 SHA256，以及 `results.json`。`--output` 可指定新的或空的目录。生成物保持在 Git 忽略目录中。

`--self-test-runner` 还实际编译运行五个独立控制样例，核对正常自检能通过、空跑/`$fatal`/失败文本/超时会被拒绝。它检查运行器；RTL 负控另外使用临时副本修改设计或模型，交付源码保持不变。

扩展清单可修改 `run.py` 中的 `TESTS`，或用 `--manifest my-tests.json` 提供 JSON 对象：

```json
{
  "tb_example": {
    "sources": ["project/rtl/example.v", "tests/sim/tb/tb_example.v"],
    "top": "tb_example",
    "pass_pattern": "(?m)^PASS: tb_example$"
  }
}
```

路径相对仓库根目录，每项只编译明确列出的源码。未知测试、缺失文件和工具缺失返回非零。旧 `tb_adc.v`、`tb_eg_phy_adc_stub.v` 是行为桩练习，不列入产品通过清单。

这些测试证明所列抽象接口的 RTL 功能，未证明模拟输入精度、跨时钟亚稳态可靠性、TD 布局布线/静态时序、引脚电气条件或实板行为。ADC 行为模型依据官方 16 拍转换/4 拍采样/EOC 一拍契约，未解密官方模型，也不模拟真实压力传感器。
