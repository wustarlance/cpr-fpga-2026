# 厂商 HDL / IP（从参考例程内置）

本目录的源码原本位于安路官方参考例程 `05_lab_ex/lab_ex5_i2s/src/user_source/hdl_source/`，
提交版本已把参考例程整体移除，主工程实际依赖的 12 个文件搬到此处，避免构建依赖仓库外的树。

| 文件 | 作用 | 形式 |
|---|---|---|
| `hdmi_phy_warpper.v` / `lane_lvds_10_1.v` | HDMI TMDS 发送与并串转换 | 明文 |
| `hdmi1.4b_transmitter_core/hdmi_1_4b_transmitter_core_wrapper.enc.v` | HDMI 1.4b 发送核 | **加密** |
| `include/sdr_as_ram.enc.v` / `include/sdr_wrrd.enc.v` | SDRAM 控制器 | **加密** |
| `IP/afifo_16_32_256.*` / `IP/afifo_32_16_256.*` | 跨时钟域 FIFO（`.v` 源码 + `.ipc` 配置 + `.tcl` 约束） | 明文 |
| `startup_pulse.v` | 上电复位脉冲 | 明文 |

- `global_def.v` 等公共头文件在 `project/vendor/include/`，构建时由 `filelist.f` 的 `-I` 指定。
- 引用位置：`project/project.al`（8 处）、`project/filelist.f`、`project/build*.tcl`（FIFO 约束）、`tests/sim/run.py`。
- **版权**：以上为安路科技提供的参考实现，版权归厂商所有，**不在本仓库 MIT 许可范围内**（见根 `LICENSE`）。
- 加密文件由 TD 工具链在综合时解密，本仓库不含任何解密后的源码。
