# TD 6.2.1 SP1 安装记录与验收自检

> 日期：2026-09-18
> 起因：比赛要求统一使用 **TD 6.2.1**，本机原装的是 6.2.3，需要替换。
> 结果：**已全部完成** —— 6.2.1 SP1（178840）装好并通过端到端自检；6.2.3 已卸载；`td` 命令已系统级切换；安装包已删除。

---

## 〇、结论速览

| 项目 | 结果 |
|---|---|
| 装了什么 | **TD 6.2.1 SP1**，内部版本号 **178840**（程序自报 `Tang Dynasty, V6.2.178840`） |
| 装在哪 | `/home/starlance/FPGA_Contest/.tools/anlogic-td/TD_6.2.1_SP1_178840_NL/`（工作区内），2.7 GB |
| 怎么启动 | 系统命令 **`td`** 已经是 6.2.1（`/usr/local/bin/td`）；也可直接调 `.tools/td` |
| 许可证 | 已放好，与 U 盘原件**字节完全相同**，有效期至 2029-08-17，`HOST_ID = ANY` |
| 验收自检 | ✅ **通过**：`read_verilog → read_adc → optimize_rtl → optimize_gate → place → route → bitgen` 全通，生成 `.bit` 629,629 字节 |
| 6.2.3 卸载 | ✅ **已完成**（19:23），`/opt/anlogic-td` 整个目录已移除，回收 2.7 GB |
| 系统级切换 | ✅ `/usr/local/bin/td` 已指向 6.2.1；原 6.2.3 启动器备份为 `/usr/local/bin/td.bak-623` |
| 安装包 | ✅ 已删除（19:24），回收 1.9 GB |
| 磁盘 | ✅ **14 GB 可用（86%）**，见第七节 |

---

## 一、为什么一开始装不到 `/opt`（环境真相）

`04_环境与工具/安路TD_Linux版获取速查.md` 里的原步骤是 `sudo mkdir -p /opt/anlogic-td` + `sudo unzip`。**当时这四步走不通**，原因不是配置错误，而是三层叠加：

**① 整个根文件系统对我是只读的。** 从进程列表里抓到了实锤：

```
bwrap --ro-bind / / --dev /dev --unshare-pid --proc /proc --die-with-parent \
      --tmpfs /tmp --bind /home/starlance/FPGA_Contest /home/starlance/FPGA_Contest
```

这是我（AI 助手）运行命令时所在的 **DSH 沙箱**（bubblewrap）：`/` 被只读绑定，只有工作区被额外 rw 绑定。

> ⚠️ **这条只影响我，不影响你。** 你自己的终端不在这个沙箱里。**这不是硬盘故障，机器没问题。**

**② `sudo` 被内核封死。**

```
sudo: /etc/sudo.conf is owned by uid 65534, should be 0
sudo: The "no new privileges" flag is set, which prevents sudo from running as root.
```

`no_new_privs` 已置位，`sudo` 无法提权 —— 连沙箱内 root 都拿不到。

**③ `/opt/anlogic-td` 的属主不是我们。** 当时显示 `drwxr-xr-x nobody:nogroup`，我们是 uid 1000，没有写权限。

### 📌 后续变化（重要，别被上文误导）

后来你把会话策略改成了 `danger-full-access`，环境随之变了：

| 检查项 | 策略变更前 | 策略变更后 |
|---|---|---|
| 根挂载 | `ro`（bwrap `--ro-bind / /`） | **`rw`**（沙箱解除） |
| `NoNewPrivs` | `1`（sudo 被封死） | **`0`** |
| `/opt/anlogic-td` 属主 | `nobody:nogroup`（沙箱假象） | **`root:root 755`**（真实属主） |
| `starlance` 是否在 sudo 组 | — | **是**（`sudo:x:27:starlance`） |

**但沙箱权限 ≠ Unix 文件权限。** 实测 `rm -rf /opt/anlogic-td/TD_Release_2026.2_NL` 仍被内核拒绝（`权限不够`，EACCES）—— 因为那是 root 的目录，而 `sudo` **需要密码**，助手无法提供。所以最终卸载仍是**由你手动执行脚本**完成的（见第六节）。

> 结论：**危险的不是"有没有沙箱"，而是"文件属主是谁"。** 只要目录属 root，非 root 身份无论有无沙箱都动不了。

---

## 二、实际安装步骤（已执行）

```bash
W=/home/starlance/FPGA_Contest

# 1. 解压到工作区（约 12 秒）
mkdir -p "$W/.tools/anlogic-td"
unzip -q -o "$W/.td_download/TD_6.2.1_SP1_178840_NL.zip" -d "$W/.tools/anlogic-td/"

# 2. 放许可证（从 /opt 那份 6.2.3 的 license 目录复制，与 U 盘原件相同）
cp /opt/anlogic-td/TD_Release_2026.2_NL/license/Anlogic.lic \
   "$W/.tools/anlogic-td/TD_6.2.1_SP1_178840_NL/license/"

# 3. 启动器（见第三节）
chmod 755 "$W/.tools/td"
```

解压后目录结构与 6.2.3 完全一致：`arch bin board_designs cw doc ip lib license packages pubkey scripts sim_release template verify`。

**包完整性**（下载后已校验，**安装包已于 2026-09-18 19:24 删除**）：

| 项目 | 值 |
|---|---|
| 文件名 | `TD_6.2.1_SP1_178840_NL.zip` |
| 大小 | 1,963,336,026 字节（≈ 1.9 GB） |
| SHA-256 | `c5917d6ae54e118e0b607063e4612d5ae21ab8bfb5b4a4988b28f67160b86839` |
| 位置 | `.td_download/TD_6.2.1_SP1_178840_NL.zip` —— **已删除**，需重下请用第五节的直链 |

---

## 三、启动器：`.tools/td`

```bash
/home/starlance/FPGA_Contest/.tools/td    # 直接调用
td                                        # 系统命令也是它（/usr/local/bin/td 已转发过来）
```

它做三件事：指向 6.2.1 的 `bin/td.sh`（由它设置 `LD_LIBRARY_PATH`）、把 `TMPDIR` 指到 `/tmp`、**把 `HOME` 重定向到 `.tools/.td_home`**。

**为什么要改 HOME**：助手所在沙箱里家目录只读，重定向能让脚本在有/无沙箱两种环境下行为一致，避免 TD 中途写配置失败。

`.tools/td621` 是指向 `td` 的软链接，用于需要显式标明版本时。

> ⚠️ 仍然**不要直接运行 `bin/td`**（缺 `LD_LIBRARY_PATH`）。

---

## 四、验收自检（端到端跑通）

自检工程在 `.tools/selftest/`，是一个与比赛无关的最小设计（24 位计数器分频点亮 4 个 LED），**只为验证工具链和许可证**，可随时删除。

```bash
cd /home/starlance/FPGA_Contest/.tools/selftest
/home/starlance/FPGA_Contest/.tools/td selftest.tcl
```

**8 步全部 ok**：

| 步骤 | 命令 | 结果 |
|---|---|---|
| 载入器件库 | `import_device eagle_s20.db -package EG4S20BG256` | ok |
| 读入设计 | `read_verilog -file selftest.v -top selftest` | ok |
| 引脚约束 | `read_adc selftest.adc` | ok |
| 综合优化 | `optimize_rtl` | ok |
| 门级优化 | `optimize_gate -packarea` | ok |
| 布局 | `place` | ok |
| 布线 | `route` | ok |
| 位流 | `bitgen -bit selftest.bit` | ok |

**许可证确实生效的证据** —— 日志里出现 4 次（综合/布局/布线/位流各一次），且指向**新装的目录**，全程零许可证报错：

```
RUN-1001 : Open license file /home/starlance/FPGA_Contest/.tools/anlogic-td/TD_6.2.1_SP1_178840_NL/license/Anlogic.lic
```

**设计真的建起来了的证据**（排除"只是空跑"的可能）：

```
HDL-1200 : Current top model is selftest
HDL-1100 : Inferred 0 RAMs.
SYN-2001 : Map 6 IOs to PADs of model 'selftest'      ← clk + rst_n + led[3:0] = 6 个 IO，对上
```

**产物**：`selftest.bit`，629,629 字节（与参考工程位流同为 615 KB 量级，大小合理）。
**时序**：布线后 `Setup WNS = 13641`、`Setup TNS = 0`、`Num of violated S-EP = 0`，无违例。

### 踩到的一个坑（记录备查）

我最初在脚本里写了 `read_verilog` 之后再单独调一次 `elaborate -top selftest`，结果报：

```
HDL-8104 ERROR: No parsing found. Need analyze step before elaborate
```

**原因**：`read_verilog` **内部已经做完了 analyze + elaborate**（日志可见 `HDL-1007 : analyze verilog file` → `HDL-1007 : elaborate module selftest`），再调 `elaborate` 时已经没有待解析的内容了。**这条命令是多余的，不是错误。**

### 一个环境限制

助手**不能启动 TD 的 GUI**：沙箱把 `/tmp` 换成了私有 tmpfs，X11/Wayland 的 socket（`/tmp/.X11-unix/`）不可见。上面这个自检是**纯命令行**流程，不需要图形界面，所以能跑通 —— **要开 GUI 请在自己的终端里敲 `td -gui`**。

---

## 五、🔴 官网标签错位：6.2.1 有两个文件，标签是反的

从官网后端接口（分类号 782 = TD Linux）逐条查证，2025-09-26 那批有**两个** 6.2.1 文件，**列表显示的标签和实际下载到的文件对不上**：

| 官网条目 | 列表显示的文件名 | **实际下载到的文件** | SHA-256 |
|---|---|---|---|
| `data-id=1111` | `TD_6.2.1_Release_175876_NL.zip` | **`TD_6.2.1_SP1_178840_NL.zip`** | `c5917d6ae54e118e0b607063e4612d5ae21ab8bfb5b4a4988b28f67160b86839` |
| `data-id=1107` | （该行无文件名标签） | `TD_6.2.1_Release_175876_NL.zip` | `2bb8d82947c205617268961b37650203ea90c73a348f227bc03e4c904c6408c2` |

**我们能确认拿到的是 SP1 178840**，证据是解压后的程序自报版本号：

```
Tang Dynasty, V6.2.178840
Built at = 2025, 11月 3
```

（178840 的构建日期是 2025-11-03，比标签写的 2025-09-26 更晚，与"SP1 是后续补丁"吻合。）

### 两条直链

```
# ① 6.2.1 SP1（178840，本次已安装，程序自报 V6.2.178840）
https://anlogic.oss-cn-shanghai.aliyuncs.com/web_doc/工具与资料下载/软件工具/TD_Linux/TD_6.2/ggshdjsgkdjh/TD_6.2.1_SP1_178840_NL.zip

# ② 6.2.1 Release（175876，真正的 9 月首发版，本机没有）
https://anlogic.oss-cn-shanghai.aliyuncs.com/web_doc/工具与资料下载/软件工具/TD_Linux/TD_6.2/ggshdjsgkdjh/TD_6.2.1_Release_175876_NL.zip
```

### ⚠️ 需要你确认的一件事

比赛通知说"统一用 6.2.1"。现在有 **6.2.1 Release（175876）** 和 **6.2.1 SP1（178840）** 两个。两者大版本号都是 6.2.1，SP1 是补丁包（一般更稳）。**建议问一下组委会/技术支持是否接受 SP1**；如果要求严格对应 175876，告诉我，我把 ① 换成 ② 重装一遍（同一步骤，约 10 分钟）。

---

## 六、卸载 6.2.3 与系统级切换（✅ 已完成）

助手做不到（`/opt` 属 root + `sudo` 需密码，见第一节），所以由**你在自己的终端**执行：

```bash
sudo /home/starlance/FPGA_Contest/.tools/系统级切换TD到6.2.1.sh
```

脚本做三件事：

1. **备份并改写 `/usr/local/bin/td`** → 转发到工作区的 6.2.1 启动器（原文件备份为 `td.bak-623`）；
2. **`rm -rf /opt/anlogic-td/TD_Release_2026.2_NL`** → 删掉 6.2.3（2.7 GB），空的 `/opt/anlogic-td` 也一并清理；
3. **验证**：以 `starlance` 身份跑一次 `td`，确认打印 `Tang Dynasty, V6.2.178840`。

> **顺序很重要**：不要只跑 `sudo rm -rf`。删掉 6.2.3 后 `/usr/local/bin/td` 会指向不存在的路径，`td` 命令直接失效 —— 脚本把"重定向"和"删除"绑在一起正是为了这个。

### 执行结果（2026-09-18 19:23）

| 检查项 | 结果 |
|---|---|
| `/opt/anlogic-td` | ✅ **整个目录已删除**（连空的父目录都清理了） |
| `/usr/local/bin/td` | ✅ root 属主，指向 `.tools/td`（19:23:25 生成） |
| `td.bak-623` | ✅ 保留（150 字节，原 6.2.3 启动器） |
| `td` 实跑 | ✅ `Tang Dynasty, V6.2.178840` |
| 磁盘 | ✅ 8.6 GB → **12 GB** |

### 脚本设计上的一个缺陷（已修）

原脚本的验证步骤以 **root** 跑 `td`，而启动器会把 `HOME` 指到 `.tools/.td_home` —— 那会让 TD 生成 **root 属主**的配置文件，之后你以 `starlance` 身份跑 `td` 就无写权限、可能启动失败。

已改为 `runuser -u starlance --` 降权执行，并在结尾加了一道 `chown -R starlance:starlance .td_home` 作为双保险。

### 副作用提醒

有 5 个 TD 自动生成的 `run.sh` 里硬编码了旧的 6.2.3 路径，现在会**报错退出**（而不是静默用错版本，这是安全的失败方式）：

```
projects/run.sh
projects/cnt1s_Runs/syn_1/run.sh
projects/cnt1s_Runs/phy_1/run.sh
05_lab_ex/lab_ex5_i2s/src/td_project/run.sh
05_lab_ex/lab_ex5_i2s/src/td_project/HDMI1.4b_Transmitter_v1.0_Runs/syn_1/run.sh
```

在 6.2.1 里打开工程并保存后 TD 会自动重写它们。

---

## 七、磁盘空间（已缓解）

| 时间点 | 可用空间 | 使用率 |
|---|---|---|
| 装之前 | 12 GB | 88% |
| 装完 6.2.1 后 | 8.6 GB | 91% ⚠️ |
| 卸载 6.2.3 后 | 12 GB | 88% |
| **删掉安装包后** | **14 GB** | **86%** ✅ |

`/` 与 `/home` 是同一个分区（96 GB，已用 78 GB）。目前余量健康，但**不适合再并存第二份 TD**（每份 2.7 GB）。

安装包已删（1.9 GB）；需要重装时在第五节的直链重下即可，下载后请核对 SHA-256。

---

## 八、下一步：这套环境要解决的真正问题

6.2.1 装好只是**前提**。参考工程 `lab_ex5_i2s` 目前**仍然编不过**，原因是历史和版本问题，与本次安装无关：

| 问题 | 说明 | 状态 |
|---|---|---|
| **IP 版本不匹配** | `user_source/hdl_source/ip/` 下 4 个 IP（`video_pll` / `afifo_16_32_256` / `afifo_32_16_256` / `afifo_16_256`）是 **TD 5.6.119222** 生成的，6.2.3 打开工程时静默丢弃这 4 条路径，于是 `sys_pll` / `video_pll` / `wfifo_32_32_512` / `rfifo_32_32_512` 全变黑盒 | ❗ 未解决 |
| **`.al` 已被 6.2.3 污染** | 工程文件里写着 `<TD_Version>6.2.3.210850</TD_Version>`，且**没有干净的原始副本**（`.al.td623-mangled.bak` 同样是 6.2.3 的） | ❗ 未解决 |
| **目录大小写** | `.al` 里引用的是 `hdl_source/ip/`，实际目录名曾是 `IP`（Linux 大小写敏感），已改名修复 | ✅ 已修 |

**方向**：用 6.2.1 **重新生成那 4 个 IP**，而不是继续修那个被污染的 `.al`。这是下一件该做的事。
