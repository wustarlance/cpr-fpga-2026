# 后仿真脚本

配合 `tests/sim/postsim/run_postsim.py` 使用，完整说明与本次结果见
[`docs/timing-postsim-20261026.md`](../../docs/timing-postsim-20261026.md)。

| 文件 | 作用 |
|---|---|
| `export.tcl` | 从已布线的 `build/<top>/route.db` 导出网表 + SDF，不重跑 P&R |
| `sta_recheck.tcl` | 只复核时序：`import_db` → `update_timing -mode final` → 状态汇总 + 路径明细 |

```bash
cd project
CPR_TOP=top     /d/ANLU/TD_6.2.1/bin/td_commands_prompt.exe scripts/postsim/export.tcl
CPR_TOP=top_adc /d/ANLU/TD_6.2.1/bin/td_commands_prompt.exe scripts/postsim/export.tcl
cd ..
python tests/sim/postsim/run_postsim.py --top top --top top_adc \
    --modelsim "D:/Program Files/Mentor Graphics ModelSim SE-64 10.6e/win64"
```

产物：`build/<top>/simulation/{<top>_sim.v,<top>.sdf,sta_recheck.rpt,timing_recheck.rpt}`。
除两份 `.rpt` 外都可以删，重跑时再导出。

三个要点（细节见报告第 2、3 节）：

- `write_verilog` 的 `-sdf` 参数会把 `$sdf_annotate` 写进网表，路径建议给绝对路径；
  否则 vsim 的工作目录一变就 `ENOENT`。
- `write_sdf` 是独立命令（`write_sdf -file xxx.sdf`），网表里不会自动带反标。
- TD 的 `EG_PHY_PLL` 不出 `extlock`，测试平台必须 `force` 锁定信号，否则设计
  被 `por_reset_n` 永久复位。
