# EG4S20 SDRAM / ECO 诊断最小工程

仅用于 TD 6.2.168116、EG4S20BG256 的实现诊断。工程是一个32位计数器加 `EG_PHY_SDRAM_2M_32` 原语，实测占用23 LUT、32寄存器，没有 PLL、BRAM、SD 卡、音频、HDMI、CPR 逻辑或加密控制器。

SDRAM 命令脚固定为 NOP，未实现初始化或读写控制器。脚本不生成位流，不下载板卡。完成布局布线只证明这个诊断构建执行完毕，不能称为 SDRAM 功能或板级时序验收通过。

在本目录使用本机 TD（以下路径按安装位置修改，传给 TD 的脚本路径使用 `/`）：

```powershell
$env:CPR_PROBE_LABEL = 'unconstrained'
& 'E:/BaiduNetdiskDownload/HX4S20_Contest_202606/anlu/td/bin/td_commands_prompt.exe' './build.tcl'
$env:CPR_PROBE_LABEL = 'fixed'
& 'E:/BaiduNetdiskDownload/HX4S20_Contest_202606/anlu/td/bin/td_commands_prompt.exe' './build.tcl'
Remove-Item Env:CPR_PROBE_LABEL
```

`unconstrained` 不加宏位置约束；`fixed` 读取 `macro.adc`，指定本机实际观察到的网格位置 `x20y36z0`。此位置不是从其他型号复制的，物理报告对应 `x=164,y=288`、`col=20,row=36`。

本轮两种配置均复现 PHY-7002 和 PHY-5079；固定配置报告 `IsFixed=True` 但仍有重定位诊断。脚本在 `route` 后又调用一次 `report_route_status -drc`，所以同一条 PHY-5079 会记录两次，不能当成两个独立问题。

进入 `control/`，用同样命令运行 `unconstrained`，可执行去掉计数器的对照。其余四个输入文件、布局强度和约束都与主目录一致。该对照实测0 LUT、0寄存器、0条关键告警；它没有实际用户时钟负载，不能用其零告警结论替代产品验证。

原始日志、报告不入库。源码哈希及实际执行结果见 [2026-10-25 排查记录](../../../project/docs/td-critical-audit-20261025.md)。
