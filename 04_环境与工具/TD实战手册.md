# TD（TangDynasty）实战手册 —— 给本项目用的

> 整理日期：2026-09-20 · 适用版本 **TD 6.2.1 SP1 (178840)**
> **来源**：① 官方手册 `TD_User_Guide_V6.2.pdf`（244 页，本地 `$TD/doc/`）② 官方 FAQ 专区 ③ 我自己在 TD 上实测
> **用法**：这是**速查手册，不是教程** —— 按需跳读，不用从头看

---

## 〇、先看这张表：TD 有哪些工具（别漏掉能省事儿的）

| 工具 | 在哪 | 干什么 | 你们什么时候用 |
|---|---|---|---|
| **IP Catalog** | `Tools → IP Catalog` | 图形化生成 IP（PLL/FIFO/ROM…） | ⭐ **立刻**：要重新生成 4 个 IP |
| **Report IP Status** | `Tools → Report IP Status` | 列出工程里所有 IP 的状态/版本、能否升级 | ⭐ **立刻**：检查 IP 版本 |
| **Module Packager** | `Tools → Module Packager` | 把**自己的 RTL** 打包成 IP | W3 之后，3 人分工时 |
| **Design Integrator** | `Tools → Design Integrator` | 把多个 design 集成为一个 | 多人分工时（可选） |
| **HDL2Bit Flow** | 左侧 Flow 面板 | 主流程：读入→RTL优化→门级→布局→布线→位流 | 每次构建 |
| **Timing Report** | `Tools → Timing Analyzer → Timing Report` | 时序分析（能按 From/Through/To 查具体路径） | ⭐ 处理 −6.3 ns 违例 |
| **Schematic Viewer** | `Tools → ...`（工具集） | **看综合后的电路图** | ⭐ 读不懂代码时看它 |
| **Chip Viewer** | 工具集 | 看资源占用、布局、时钟树 | 查 BSRAM/时序余量 |
| **ChipWatcher (CWC)** | 工具集 | ⭐⭐ **在线逻辑分析仪**（不用示波器就能看内部信号） | ⭐ 等板子到了必用 |
| **Virtual Probe Interface** | 工具集 | 实时监控**并驱动**内部信号 | 上板调试（能"伪造"输入） |
| **ChipProbe** | 工具集 | 内部信号探测 | 备选 |
| **ATMR** | 工具集 | 时序余量分析（PH2/PH1P） | 本项目用不上（EG4） |
| **Eram Editor** | 工具集 | 编辑片上 ERAM 初始值 | 音频样本 ROM 之类 |
| **Encrypt Tool** | 工具集 | 加密 Verilog（`pragma protect`） | 一般不用 |
| **BitWizard** | 工具集 | 位流/固化文件生成向导 | ⭐ 固化到 Flash 时 |
| **Language Template** | `Tools → Language Template` | **原语/语法的代码模板** | ⭐ 写代码时查原语怎么用 |
| **板级示例工程** | 菜单里 | 官方板级例程 | 找参考写法 |
| **导出 tcl 脚本** | `Project → Export → Export Tcl File for Flow` | 把整个 flow 导成 tcl | ⭐ 脚本化重建工程 |

---

## 一、工程管理（你们已经踩过的坑）

### 1.1 `Hierarchy` 面板 = 例化树，不是文件树 ⭐

`Hierarchy Navigation` 面板里其实有**两个界面**（官方手册 2.1.3 节原文确认）：

| 界面 | 内容 | 什么时候用 |
|---|---|---|
| **`Project Hierarchy`** | **例化树**（`实例名 - 模块名 (文件) (子实例数)`） | 看电路结构、看谁例化了谁 |
| **`Compile Order`** | ⭐ **扁平的、按编译顺序的文件列表** | **找文件用这个**（最接近 VS Code 的视角） |

**三个配合动作**：

| 动作 | 位置 | 说明 |
|---|---|---|
| `Refresh Hierarchy` | 右键 `Hierarchy` 节点 | **在 VS Code 里新增/改名/删除 .v 之后必须做这个**，TD 不会自动发现 |
| `Set As Top` | 右键目标模块 | 顶层是**自动识别**的（标紫色）；识别错了手动改（标蓝紫） |
| 双击某行 | — | 跳到对应源码 |

**记住一个反例**：`ip/afifo_16_32_256.v` 里定义的模块叫 **`wfifo_32_32_512`** —— **文件名 ≠ 模块名**。所以"按文件名找"在 TD 里会失败，要**按模块名找**。

### 1.2 ⭐ ADC 约束的一条铁律（直接影响你们写约束）

官方手册 9.1 节原文：

> "其中，对于位置约束（LOCATION），将检查目标位置是否合法，以及是否有多个管脚被分配至同一位置，**一旦添加了 ADC 文件，要求为所有管脚锁定位置**。"

👉 **只要工程里有 `.adc` 文件，就要求所有 IO 都有位置约束**。否则位流生成会直接报错（我们在自检时就撞到过 `BIT-8123 Bitgen is prohibitted as there are unconstrained io(s)`）。

**给你们的意义**：写约束时**不能只写一部分** —— 只要加了一个 `.adc`，就得把所有用到的引脚都写上。**这是好事**（强迫你把引脚固定下来，避免综合器随机分配）。

**ADC 文件语法**（含 10 个可设属性）：

```tcl
set_pin_assignment { 端口名 } { LOCATION = 管脚; IOSTANDARD = 电平; ... }
```

| 属性 | 可选值 |
|---|---|
| `BANK` | BANK1 ~ BANK8 |
| `LOCATION` | 芯片管脚名（如 `R7`） |
| `IOSTANDARD` | `LVCMOS12/15/18/25/33`、`LVDS25`、`LVDS25_E`、`LVDS33`、`LVDS33_E`、`PCI33`、`LVTTL33`、`LVPECL33`、`LVPECL33_E` |
| `DRIVESTRENGTH` | 2, 4, 8, 12, 16, 20, NA |
| `PULLTYPE` | PULLUP, PULLDOWN, NONE, KEEPER |
| `SLEWRATE` | FAST, MED, SLOW |
| `DIFFRESISTOR` | 100, NONE |
| `PCICLAMP` | ON, OFF |
| `PACKREG` | AUTO, ON, OFF |
| `PREEMPHASIS` | 仅 LVDS 输出需要（`LVDS_E` 是模拟 LVDS，不支持预加重） |

差分对还可以设 `VCM` / `VOD`（**只对 LVDS25 / LVDS33 有效**）：

```tcl
set_pin_assignment { sys_clk } { LOCATION = A3; IOSTANDARD = LVDS33; VCM = 0.8; VOD = 350m }
```

> 📖 完整属性表见官方手册 **9.1 节（打印页 157~159）**；SDC 语法见 **9.2 节（打印页 160~167）**。

### 1.3 脚本化构建：导出 tcl ⭐

**为什么值得做**：你们反复重建工程时，GUI 点来点去很容易漏步骤。TD 能把整个 flow 导成 tcl。

**两条路**：

| 方式 | 说明 |
|---|---|
| **自动生成** | 工程跑过一次 flow 后，会自动生成 `prj_name_Runs/syn_1/prj_name.tcl` 和 `phy_1/prj_name.tcl` —— 各自记录了该阶段的**完整命令** |
| **手动导出** | `Project → Export → Export Tcl File for Flow` → 生成一个跑**完整 flow** 的 tcl |

**执行方式**（Windows）：`Start → td_commands_prompt` → `cd` 到脚本目录 → `source demo.tcl`
**执行方式**（我们 Linux）：`cd <脚本目录> && <本工作区的 .tools/td > <脚本名>` ← **我们已经在用了**（`build_621.tcl`）

**冷知识**：在 run 目录放一个空文件 **`.stop.f`**，flow 会在下一个阶段边界停下来 —— 这是 TD 自己脚本里的机制（`DefaultFlow.tcl` 里 `if {[file isfile .stop.f]} { halt }`）。

---

## 二、IP 生成器 ⭐（你们必须重新生成 4 个 IP）

### 2.1 IP Catalog 的正常流程

```
Tools → IP Catalog → 选 IP（Primitive / Soft / User）
    → 选存储路径 + 改模块名（默认存到工程下的 al_ip/ 文件夹）
    → 配置参数 → OK → Generate
    → 生成的文件【自动加进工程】
    → 在 IP 上右键 → Create RTL Wrapper → 自动生成例化该 IP 的顶层文件
```

IP 分三类：
- **Primitive IP**：Common / Clock / Arithmetic / Memory…（PLL、BUFG 这类）
- **Soft IP**：Arithmetic / Bus Component / DSP…
- **User IP**：**你们自己用 `Module Packager` 打包的 RTL**

### 2.2 ⭐⭐ 官方对"IP 升级不了"的答复（正中我们的情况）

官方 FAQ 里有人问：

> **问**：尝试使用了 TD6.2.1 但是会提示 **IP 无法更新**，是否有办法解决。
>
> **官方答**：可以使用 TD6.2 系列软件，最新软件版本支持 PH1 和 EG4 2 个系列软件。**因为软件版本更新迭代比较大，所以新软件版本 IP 你可以删除重新新建。**

👉 **这就是我们参考工程那个问题的官方答案**：跨大版本（5.6 → 6.2）的 IP **不要试图升级，直接删掉重新生成**。（我们的做法完全一致：补文件也好、重新生成也好，本质都是"让 6.2.1 自己产出 IP"。）

### 2.3 `Report IP Status` —— 检查 IP 状态的工具

`Tools → Report IP Status` 会列出每个 IP 的：

| 列 | 含义 |
|---|---|
| `Source File` | IP 的配置文件（`.ipc`）路径 |
| **`IP Status`** | 当前状态（是否需要升级） |
| **`Recommendation`** | 建议动作 |
| `Change Log` | 变更记录 |
| `IP Name` | IP 名字 |
| `Current Version` / `Recommended Version` | 当前版本 / 推荐版本 |
| `Current Part` | 当前器件 |

**能升级的 IP 前面有勾选框** → 勾上 → 点 `Upgrade Selected` → 进度条走完 → **工程文件自动刷新**。

> 👉 **你们重建工程后，第一件事就是打开这个面板扫一眼** —— 它会直接告诉你有没有 IP 版本不匹配。

### 2.4 器件不支持某个 IP 时的绕法 ⭐

官方 FAQ 里有人问"EG4X20 的 IP Catalog 里搜不到 FFT"，官方答：

> "小器件 DSP 的数量比较少，很受限，所以通过软件锁住了。**你如果花费资源不多，可以在其他器件下生成，然后拷贝 verilog 文件直接在你的当前器件工程里使用。**"

👉 **通用技巧**：某个 IP 在当前器件下被锁住时，**换个器件生成，再把生成的 `.v` 拷进工程**。对我们有用的是：万一某个 FIFO/ROM 配置在 EG4 下不给生成，可以试这条路。（⚠️ 但要确认生成的原语在 EG4 上存在，否则会变黑盒 —— 这正是我们踩过的坑。）

### 2.5 `Module Packager` —— 把你们自己的 RTL 打包成 IP（3 人分工用）

| 功能 | 说明 |
|---|---|
| 自动解析 RTL 并识别端口 | — |
| 解析模块参数，作为 IP 的参数 | — |
| 支持总线绑定 | — |

**限制**（官方明确列出）：
1. **只支持 Verilog**（VHDL / System Verilog 还在开发）
2. **只支持单个 RTL 文件** —— 多个文件要**手动合并成一个文件**再打包
3. **不支持添加约束文件**

> 💡 **对 3 人分工的意义**：一个人写的模块（比如 `rate_judge`）可以打包成 IP 交给另一个人例化，接口清晰、不用共享源码。**但要注意"单文件"限制**。

### 2.6 IP 手册在哪

官方 FAQ 答复：**部分 IP 的手册没上传官网，但已打包进软件** → 在软件里 `Help → IP User Guide` 阅读。找不到就联系本地 FAE。

---

## 三、调试工具 ⭐⭐（等板子到了，这一节最值钱）

### 3.1 `ChipWatcher`（CWC）—— 免费的"在线逻辑分析仪"

官方手册原文：

> "ChipWatcher，为**内部逻辑在线分析工具**。通过 ChipWatcher 用户**无需借助外部设备**即可在线监测电路内部信号的变化情况。在 ChipWatcher 中，用户可**同时添加多个观察信号，支持多个时钟域**，每个时钟域分为不同界面独立观察信号、独立设置**采样深度、触发条件及触发位置**等。"

**这对你们意味着什么**：你们方案里最需要"看波形"的地方（ADC 采样值、按压判定状态机、SD 卡命令流、音画同步计数器），**都不需要示波器/逻辑分析仪，直接看就行**。

#### 4 种插入方式（官方列出）

| # | 方式 | 说明 |
|---|---|---|
| 1 | 源码插入 ChipWatcher IP | 在代码里例化 |
| 2 | **源码添加 `mark_debug` 命令** ⭐ | 在信号上加 `(*mark_debug="true"*)` |
| 3 | `Read Design` 后添加 Mark Debug 标记 | 综合后从网表里选信号 |
| 4 | `Optimize Gate` 后插入 ChipWatcher | 更后期插入 |

**既能监测源代码信号，也能监测网表信号。**

**官方 FAQ 关于"怎么加模块内部信号"**：
> "方式有很多种：**源代码中添加 `(*mark_debug="true"*)`**，或者 IP 例化做链接，或者工程中直接找该信号进行添加。"

#### ⚠️ 三个已知坑（都是官方 FAQ / 竞赛同行踩的）

| # | 坑 | 官方说明 |
|---|---|---|
| 1 | ⭐ **CWC 是 read-only，改不了** | 有**参加嵌赛的同学**（2025-08-27）问了同样的问题。官方答：**"CWC 在 TD 运行中，编辑只有几个过程可以 —— `Read Design`、`Gate`；比如在 `route` 了就不可以编辑"**<br>👉 **所以要在早期阶段就把观察信号加好**，跑到后面就锁死了 |
| 2 | ⭐ **采样时钟频率不够，波形会乱** | 官方答："**采样时钟和采样数据不是同一个时钟**导致，频率过低或不同频同相。**如果不同频，采样时钟至少 3 倍于目标数据时钟**" |
| 3 | 导出的 `.csv` 不能反向打开 | "CSV 主要是存储波形数据，部分使用这个数据做二次分析，比如 **matlab**" |

> 📖 详细用法见 **`SWUG111 Debug Tools User Guide` 第 2 章**（软件里 `Help → Software User Guide → SWUG111`）

### 3.2 `Virtual Probe Interface` —— 能**驱动**内部信号

官方原文：

> "Virtual Probe Interface 可以**实时监控和驱动** FPGA 内部信号，用于协助用户上板调试……**可以代替外部管脚向 FPGA 内部输入信号**，从而控制 FPGA 内部信号，同时用户可以实时监控通过 Virtual Probe Interface 驱动的内部信号。"

👉 **区别**：ChipWatcher 只能**看**，Virtual Probe 还能**喂** —— 比如你想测试"按压速率超限"的分支，但手头没有按压盒，就可以**用 Virtual Probe 伪造 ADC 数据**。**对你们 W1 验证 ADC、W6 验证三模式非常有用。**

### 3.3 `Schematic Viewer` —— 看综合后的电路图 ⭐

**用途**：读不懂代码、或想确认"综合器把我的 always 块变成了什么"时，**直接看电路图**。
比如：确认某个 `case` 有没有被优化成 ROM、某个信号有没有被推断成 BRAM。

### 3.4 `Chip Viewer` —— 看资源占用与布局

**用途**：查 LUT/BSRAM/DSP 用量、看模块在芯片上的物理位置、看时钟树。
**对你们**：验证"多图层方案还剩多少 BSRAM"时用它比看报告直观。

### 3.5 其余

| 工具 | 用途 |
|---|---|
| `ChipProbe` | 内部信号探测（备选方案） |
| `Eram Editor` | 编辑片上 ERAM 的初始值（音频样本 ROM 之类） |
| `ATMR` / `HXT Margin Analysis` | 高速接口时序余量分析（**PH2 / PH1P 专属，EG4 用不上**） |
| `I/O State Editor` | IO 状态编辑器 |
| `Encrypt Tool` | 加密 RTL（块加密：加起止语） |

---

## 四、时序 ⭐（你们有一个 −6.3 ns 违例要处理）

### 4.1 怎么打开 Timing Report

**两个入口**：
1. `Design Summary → Timing Summary` → 双击 `Timing Report`
2. `Tools → Timing Analyzer → Timing Report`

**前提**：Flow 跑完 `Optimize Gate`/`Placement`/`Routing` 之后，**执行 `Open Run`**，才能启动时序分析。

### 4.2 Timing Options 里的关键设置

| 项 | 默认 | 含义 |
|---|---|---|
| `Path Delay Type` | `Max_Min` | Max = setup（建立）、Min = hold（保持），两者都报 |
| `Multi Corner` | `Slow_Fast` | 快慢两个角都报 |
| `EndPoints per path group` | — | 每个时钟组报多少个终点 |
| `Paths per endpoint` | — | 每个终点报多少条路径 |

### 4.3 ⭐ 最有用的一页：`Target` 页 —— 按 From/Through/To 查具体路径

| 字段 | 用法 |
|---|---|
| `From` | 指定起点（比如某个寄存器的输出） |
| `Through` | 指定路径经过的节点 |
| `To` | 指定终点 |

👉 **处理 −6.3 ns 违例的正确姿势**：不要只看汇总报告，用 `Target` 页**把最差的那条路径单独拉出来**，看它的**起点/终点/逻辑级数**，才能判断是"组合逻辑太长"还是"约束过紧"。

**还在报告里集成了查找窗口**，支持 `get_ports` / `get_pins` / `get_regs` / `get_cells` 四种查询（可以按名字找信号）。

### 4.4 ⭐ `Command` 页能看后端 TCL

生成报告时用的 TCL 指令会显示出来，**可以直接复制到脚本里复用**（比如把"查某条路径"做成脚本，反复用）。

### 4.5 另外两个报告

| 报告 | 看什么 |
|---|---|
| **Clock Tree Report** | 时钟树结构、各时钟的扇出与延迟 |
| **Clock Intersection Report** | **跨时钟域路径交叉报告** ⭐ —— 用来复查你们那些 CDC 有没有被正确约束 |

### 4.6 ⚠️🔴 一个坏消息：**EG4 没有策略包可选**

我查了 `$TD/doc/strategies/` —— 里面**只有 `official_strategy_ph1.json` 和 `official_strategy_ph2.json`**，而 `bin/td` 里搜 `AreaOptimizeHigh` 等策略名出现 **0 次**。

| 系列 | 可用策略 |
|---|---|
| PH1A / PH1P / PH2 / DR1 | `Default`、`AreaOptimizeMedium/High`、`LogicLevelOptimize`、`AdderChainThresholdHigh`、`MacroOptimize`、`RAMOptimize`、`TimingMedium/High/Ultra`、`CongestionMedium/High`、`RuntimeOptimize`、`MacroTiming`… |
| **EG4（你们）** | ❗ **只有 `Default_Synthesis_Strategy` / `Default_PhysicalDesign_Strategy`** |

**所以**：
- ❌ **不能靠"换个时序优先的策略包"来救 −6.3 ns**
- ✅ 只能从两头解决：**改 RTL**（打拍/拆逻辑/降扇出）或**改约束/降频**

> 这是个很重要的"死路排查" —— 免得你们花时间在 GUI 里找策略下拉框。

---

## 五、下载与固化 ⭐（演示成败项）

### 5.1 TD 支持的下载模式（从 `doc/config/config.json` 提取）

| 模式 | 底层命令 | 含义 | 掉电后 |
|---|---|---|---|
| **`PROGRAM_SRAM`** | `jtag` | 下载到 FPGA 片内 SRAM | ❌ **丢失** |
| **`PROGRAM_FLASH`** | `program_spi -v` | ⭐ **固化到 SPI Flash** | ✅ **保留** |
| `VERIFY_FLASH` | `verify_spi` | 校验 Flash 内容 | — |
| `ERASE_FLASH` | `erase_spi` | 擦除 Flash | — |
| `FLASH_READ` | `rdbk_spi` | 读回 Flash | — |
| `DUAL_BOOT` | `dual_boot -v` | 双启动（Golden + 更新镜像） | — |
| `MULTI_BOOT` | `multi_boot -v` | 多启动 | — |
| `PROGRAM_SPIBIN` | `program_spibin -v` | 烧 SPI BIN | — |
| `CHECK_FLASH_STATUS` | `rdbk_spisr` | 查 Flash 状态寄存器 | — |
| `DIRECT_FLASH_WRITE` / `READ` | `program_spidir` / `rdbk_spidir` | 直写/直读 Flash | — |
| `VERIFY_SRAM` | `x_rdbk` | 回读 SRAM | — |
| `TOGGLE_RISCV_POR_RST_N` | `t_riscv_por_reset_n` | 复位 RISC-V | 本项目无关 |
| `PROGRAM_RISCV_IMG` | `program_riscv` | 烧 RISC-V 镜像 | 本项目无关 |
| `READ_SAVE_SRAM` | `save_sram` | 保存 SRAM | — |

> 👉 **你们演示必须用 `PROGRAM_FLASH`（固化）** —— 不能拖着 JTAG 线演示。

### 5.2 Flash 型号库

TD 自带**支持的 SPI Flash 器件表**：`$TD/doc/config/flash.json`（79 KB）。里面按厂商列出型号 + **ManufactureID / DeviceID / 容量 / 擦除时间 / QE 位配置**等。

**用途**：固化时 TD 要认识你板上那颗 Flash；板载是 **W25Q64（8 MB，用户 Flash）**（见 `03_技术方案/硬件实证_板卡引脚与资源对照.md`）。

### 5.3 下载器驱动

官方 FAQ：**驱动在 TD 安装目录下的 `driver` 文件夹**。

（另外我们之前已经确认：也可以用 `openFPGALoader -c anlogicCable`，绕开 TD 的 USB 驱动和那个 400 kbps 速度限制。）

---

## 六、中文字符与编码 ⚠️（直接关系到我们改过的文件）

官方 FAQ 里有个报错：

> **`ERROR: syntax error near non-printable character with the hex value 0xe60`**
> 官方答：**"初步判断你的工程，应该是使用了非英文字符，比如中文类型的分号"**

**这条要分清两种情况**：

| 情况 | 安全吗 | 说明 |
|---|---|---|
| **中文出现在 `//` 注释里** | ✅ **安全** | 原厂文件里本来就有大量中文注释（`sd_card_bmp.v`、`bmp_read.v`、`frame_fifo_write.v` 都有），我们实测 `ERROR 0` 通过 |
| **中文全角标点混进代码** | ❌ **报错** | 比如把 `;` 打成 `；`、`,` 打成 `，`、`()` 打成 `（）` —— 报的就是上面那个 `non-printable character` |

**我们改过的三个文件的实测结果**（用 TD 真跑了一遍 `read_design → opt_rtl → opt_gate`）：

```
ERROR 数: 0
HDL-1007 : elaborate module sd_card_cmd in .../sd_card_cmd.v(37)
HDL-1200 : Current top model is top
SYN-1079 : finish stage Check Design Sanity. Total instances: 21467   ← 与改注释前完全一致
```

✅ **结论：中文注释安全，且不影响综合结果**（实例数一字不差）。

> 💡 **给你们的规矩**：**注释随便写中文；代码里只准用英文半角标点。** 改完代码先扫一眼有没有全角符号。

---

## 七、附录速查（官方手册第 9 章，遇到问题来查）

| 附录 | 打印页 | 内容 | 什么时候查 |
|---|---|---|---|
| **9.1 ADC 约束说明** | 157 | IO 约束的全部属性与合法值 | 写 `.adc` 时 |
| **9.2 SDC 约束说明** | 160 | 时序约束写法 | 写 `.sdc` 时 |
| **9.3 主要警告消息说明** | **168~222** | ⭐ **55 页的错误码/警告码速查表**（含"说明 + 建议"） | **看到不认识的报错就来查** |
| **9.4 中间文件用途说明** | 223 | 列出每个中间文件是什么 | 看 run 目录一堆文件发懵时 |
| **9.5 综合后信号/单元命名规则** | 224 | 综合后网表里那些怪名字怎么来的 | 看 ChipWatcher/Schematic 时 |
| **9.6 界面 Properties 可选项说明** | 225 | 所有可设属性的含义 | 调参数时 |
| **9.7 内置策略包可选项说明** | 242 | 各策略包的功效与限制 | ⚠️ **EG4 用不上**（见 4.6） |

### 7.1 ⭐ 用 9.3 表查我们踩过的错误码（官方原文）

| 错误码 | 官方说明 | 官方建议 | 我们的实际情况 |
|---|---|---|---|
| `HDL-8104` | 非法的 FLOW 流程 | 内部错误/流程问题，请咨询技术 | ✅ 我们自己定位了：`read_verilog` 已含 elaborate，**多余的一次 `elaborate` 触发** |
| `PRJ-8641` | AL 文件格式错误，文件损坏 | 联系技术支持 | ✅ 我们自己定位了：**6.2.3 写的 XML 注释，6.2.1 解析器不认** |
| `PRJ-8640` | 打开 AL 文件失败 | **关注之前报的其他错误** | ✅ 它只是上面那条的"连锁反应"——**看第一条错误就够了** |
| `PRJ-9024` | 不正确的版本 | 联系技术支持 | ✅ 我们自己定位了：`<TD_Version>` 格式必须是 **`6.2.178840`** |
| `BIT-8123` | （表中文字被 PDF 抽取弄乱） | 请咨询技术支持 | ✅ 实际是 `unconstrained io` —— 见 1.2 那条 ADC 铁律 |
| `USR-8022` | 用户选择的 Pad 在 package 中不存在 | 请参考用户手册 | 写错管脚名时会遇到 |

> ⭐ **一条通用经验（从 `PRJ-8640` 学到的）**：TD 报错经常是**连锁的** —— 后面那条通常只是前面那条的后果。**永远先修第一条。**

### 7.2 中间文件速查（9.4 节节选）

| 文件 | 含义 |
|---|---|
| `prj_name.tcl` | 该阶段的完整 flow 命令 ⭐ 可复用 |
| `prj_name.prj` | 该阶段的参数设置 |
| `.read_design.begin.f` / `.read_design.end.f` | **进度标识文件**（开始/完成） |
| `prj_name_elaborate.db` / `_rtl.db` / `_gate.db` / `_place.db` / `_pr.db` | 各阶段生成的 database |
| `prj_name_rtl.area` / `_gate.area` / `_phy.area` | ⭐ **各阶段的资源报告** |
| `run.log` | 运行日志 |
| `top_module_preroute_clock_analysis.rpt` / `postroute_...` | **布前/布后时钟分析报告** |

---

## 八、把社区经验一次列全（官方 FAQ 里的坑，附出处）

来源：[安路官方 FAQ 专区 · 软件/TangDynasty](http://tech.anlogic.com/)（`cate=32`），另有官方 wiki `https://alwiki.anlogic.com/`

| # | 别人踩的坑 | 官方答复 | 对我们的价值 |
|---|---|---|---|
| 1 | **CWC 是 read-only**（**同样是嵌赛的同学问的**） | 只有 `Read Design`、`Gate` 阶段能编辑，**route 之后不能** | ⭐⭐ 提前加观察信号 |
| 2 | CWC 波形显示乱码/无序 | **采样时钟至少 3 倍于目标数据时钟**；最好同频同相 | ⭐ 采样时钟怎么选 |
| 3 | CWC 怎么加模块内部信号 | **`(*mark_debug="true"*)`** 或从网表里选 | ⭐ 直接可用 |
| 4 | **IP 无法更新** | **删掉重新新建**（跨版本 IP 不要升级） | ⭐⭐ 正是我们的情况 |
| 5 | 小器件搜不到某个 IP（如 EG4 的 FFT） | **换个器件生成，再拷 `.v` 进工程** | ⭐ 备选绕法 |
| 6 | `non-printable character 0xe60` | **代码里混了中文全角标点** | ⭐ 见第六节 |
| 7 | 一个电脑装多个 TD 版本？ | 没问题，版本 ID 不一致 | 想留老版本也行 |
| 8 | `svf2aje.exe` 双击没反应 | **它不能双击**，要在 cmd 里带路径运行 | — |
| 9 | 下载器驱动在哪 | **TD 安装目录的 `driver` 文件夹** | 装驱动时 |
| 10 | `RUN-8418 License expired` | 联系 FAE 免费更新 | 我们的 license 到 2029 年 |
| 11 | TD 和 FD 的 license 一致 | — | — |
| 12 | ROM IP 仿真输出不定态 | 检查**初始化文件路径**是否正确 | 用 ROM IP 时 |
| 13 | 离线下载器烧 Flash 要提取 16 字节文件头 | 参考 **UG004 / TN001** | 用离线下载器时 |
| 14 | 部分 IP 没官网手册 | **已打包进软件**：`Help → IP User Guide` | 查 IP 用法 |
| 15 | 内部信号埋点后要**重新生成位流**才能看 | （常识） | — |

---

## 九、给你们项目的行动清单

### 🔴 立刻（不需要板子）

- [ ] **`Tools → Report IP Status`** 扫一遍参考工程 —— 看 IP 版本状态（这是官方推荐的检查入口）
- [ ] 重新生成 4 个 IP 时，**用 IP Catalog 走正规流程**，生成后右键 `Create RTL Wrapper`
- [ ] 建你们自己的工程时，**在 VS Code 里改文件、在 TD 里 `Refresh Hierarchy`** —— 形成固定动作
- [ ] 把 "**注释可中文、代码只用英文半角**" 写进你们的编码规范
- [ ] 用 `Project → Export → Export Tcl File for Flow` 导一份构建脚本，纳入版本管理

### 🟡 等板子到了

- [ ] **第一件事：用 ChipWatcher 看 ADC 原始数据** —— 比数码管显示高效得多
      - 采样时钟选 ≥ 3× 目标速率
      - 在 `Read Design` 阶段就把信号加好（route 后锁死）
      - 源码里用 `(*mark_debug="true"*)` 标记要看的信号
- [ ] 手头没有按压盒时，用 **Virtual Probe Interface 伪造 ADC 输入**测试判定逻辑
- [ ] 固化：`PROGRAM_FLASH`（别拖着 JTAG 线演示）

### 🔵 处理时序违例时

- [ ] 用 **Timing Report → Target 页**（From/Through/To）把 −6.3 ns 那条最差路径**单独拉出来**
- [ ] 看 **Clock Intersection Report** 复查 CDC 约束
- [ ] ⚠️ **别去 GUI 找策略包** —— EG4 只有 Default（见 4.6）

---

## 附：文档索引（本地）

| 文档 | 路径 | 页数 |
|---|---|---|
| **TD 用户手册（中文）** | `$TD/doc/TD_User_Guide_V6.2.pdf` | 244 |
| 用户手册全文（可 grep） | `_ref/规格书/_td_ug.txt` | 16827 行 |
| **调试工具手册** ⭐ | `$TD/doc/SWUG/SWUG111_Debug_Tools_User_Guide.pdf` | — |
| 设计流程手册 | `$TD/doc/SWUG/SWUG103_Design_Flow_User_Guide.pdf` | — |
| TCL 命令手册 | `$TD/doc/SWUG/SWUG105_TCL_Command_User_Guide.pdf` | — |
| HDL 编码与综合 | `$TD/doc/SWUG/SWUG106_HDL_Coding_Synthesis_User_Guide.pdf` | — |
| 时序约束 / 时序工具 | `$TD/doc/SWUG/SWUG200_Timing_Constraints…` / `SWUG201_Timing_Tools…` | — |
| 位流向导（固化） | `$TD/doc/SWUG/SWUG110_BitWizard_User_Guide.pdf` | — |
| Chip Viewer | `$TD/doc/SWUG/SWUG116_Chip_Viewer_User_Guide.pdf` | — |
| **EG4 库指南** ⭐ | `$TD/doc/UG301_EG4_Libraries_Guide_for_HDL_Designs.pdf` | — |
| 模块打包 | `$TD/doc/SWUG/SWUG507_Module_Packager_User_Guide.pdf` | — |
| 官方 FAQ（在线） | http://tech.anlogic.com/ | — |
| 官方 wiki | https://alwiki.anlogic.com/ | — |

> `$TD` = `.tools/anlogic-td/TD_6.2.1_SP1_178840_NL`
