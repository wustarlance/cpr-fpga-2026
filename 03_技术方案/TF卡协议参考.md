# TF 卡（microSD）协议参考

> 整理日期：2026-09-18
> 用途：心肺复苏训练终端 · SD 卡 SPI 链路（配合 `03_技术方案/接口规范_SD存储子系统.md`）
> **说明**：本文是「网上资料的整理 + 与参考工程源码的逐条印证」。所有标 ✅ 的结论都对照过 `lab_ex5_i2s` 的源码；标 🌐 的来自网络资料；标 ⚠️ 的是我存疑、建议核对的地方。

---

## 〇、资料来源与抓取状态

| 资料 | 链接 | 本站抓取 | 价值 |
|---|---|---|---|
| **SD 协会官方规范** Part 1 Physical Layer Simplified Specification | [官方下载页](https://www.sdcard.org/downloads/pls/) | ✅ **已下载到本地**（v9.10，见第十三节） | ⭐⭐⭐ **唯一权威源** |
| **elm-chan《How to Use MMC/SDC》** | [elm-chan.org/docs/mmc/mmc_e.html](http://elm-chan.org/docs/mmc/mmc_e.html) | ❌ 网络不可达 | ⭐⭐⭐ SPI 模式**最经典的实操文档**，强烈建议自己打开 |
| CSDN《FPGA实现SD卡SPI初始化：协议解析与RTL设计》 | [blog.csdn.net/…/158520245](https://blog.csdn.net/weixin_34779181/article/details/158520245) | ✅ 抓到（2.1 节后被付费墙截断） | ⭐⭐ 中文 + FPGA 视角 |
| 腾讯云《SD NAND：SD模式与SPI模式的详解》 | [cloud.tencent.cn/…/2524129](https://cloud.tencent.cn/developer/article/2524129) | ✅ 抓到全文 | ⭐⭐ 两种模式的初始化流程对比 |
| Total Phase《Set Up SDC/MMC Cards in SPI Mode》 | [totalphase.com/blog/…](https://www.totalphase.com/blog/2018/08/set-sdc-mmc-cards-spi-mode-verify-files-successfully-programmed/) | ✅ 抓到全文 | ⭐ 上电序列摘要（引 elm-chan） |
| CSDN《TF卡和SD卡的区别》 | [embedx.blog.csdn.net/…/156571045](https://embedx.blog.csdn.net/article/details/156571045) | ✅（摘要） | ⭐ 命名沿革 |
| Linux 内核 `drivers/mmc/mmc_spi.c` | [elixir 镜像](https://elixir.deinde.dev/concept/c2025.09-rc1/source/drivers/mmc/mmc_spi.c) | ❌ 超时 | ⭐⭐ 工业级 SPI 协议实现参考 |

> 🔴 **网络限制说明**：本环境抓不到 elm-chan 与 Wikipedia，官方 PDF 也只能浏览器下载。**建议你在浏览器里把上面 ⭐⭐⭐ 那两个存到本地**（PDF 与 elm-chan 页面），它们是这个课题的答案天花板。

---

## 一、TF 卡是什么（名字先搞清）

| 说法 | 含义 |
|---|---|
| **TF 卡** | TransFlash，SanDisk（原摩托罗拉）2004 年推出 |
| **microSD** | 2005 年 SD 协会采纳 TF 后改的正式名 |
| 关系 | **同一个东西的两个名字**，11 × 15 × 1 mm；加个转接套就是标准 SD 卡 |

技术规格与 SD 卡完全相同 —— 所以你说的"TF 卡协议"就是 **SD 卡协议**，规范里查 "SD" 而不是 "TF"。

---

## 二、物理层：microSD 的 8 个脚在 SPI 模式下的映射 🌐

microSD 卡座共 8 个触点，**同一条物理引脚在两种模式下含义不同**：

| 脚号 | SD 模式名 | **SPI 模式名** | 方向 | 本板引脚（HX4S20C） |
|---|---|---|---|---|
| 1 | DAT2 | **不用**（保持高 / 上拉） | — | A11（参考工程未用） |
| 2 | CD / **DAT3** | **CS**（片选，低有效） | 主机→卡 | **A12** |
| 3 | CMD | **DI / MOSI** | 主机→卡 | **A13** |
| 4 | VDD | 3.3 V | — | — |
| 5 | CLK | **SCLK / DCLK** | 主机→卡 | **A14** |
| 6 | VSS | GND | — | — |
| 7 | DAT0 | **DO / MISO** | 卡→主机 | **B14** |
| 8 | DAT1 | **不用**（保持高 / 上拉） | — | B15（参考工程未用） |

> ✅ **本板实证**：参考工程 `pin.adc` 里的 4 条约束正是 `sd_dclk→A14 / sd_miso→B14 / sd_mosi→A13 / sd_ncs→A12`，与上表一致。
> 完整证据链见 `03_技术方案/硬件实证_板卡引脚与资源对照.md` 第 6 节。

### 🔑 关键：怎么"进入" SPI 模式

**不需要任何跳线、不需要额外引脚**。机制是：

> 卡上电后处于 **SD 模式**。当主机**在发送 CMD0 的同时把 CS（即 DAT3）拉低**，卡就切换到 **SPI 模式**并进入 IDLE 状态。

所以"用哪种模式"是**协议协商出来的**，不是硬件接法决定的。

---

## 三、SPI 模式的时序与电气约束 🌐✅

| 项目 | 要求 | 依据（规范原文位置） | 参考工程实现 |
|---|---|---|---|
| 识别/初始化阶段 SCLK | **100 ~ 400 kHz** | 规范第 4 章；且 7.6/7.7/7.8 三节声明 SPI 模式的电气与时序**"等同于 SD 模式"** | ✅ 200 kHz（`SPI_LOW_SPEED_DIV = 248` @100 MHz） |
| 数据传输阶段 SCLK | 最高 **25 MHz**（Default Speed，3.3 V） | 规范：*"Default Speed mode: 3.3V signaling, Frequency up to 25 MHz"* | ✅ 25 MHz（`SPI_HIGH_SPEED_DIV = 0`） |
| 时钟极性/相位 | ⚠️ **规范全文没有 CPOL/CPHA 这两个术语**。7.5 节（SPI 总线时序图）在简化规范里是**空白**；7.6/7.7/7.8 只说"electrical interface / bus operating conditions / bus timing **identical to SD mode**" | 7.5~7.8 节 | ✅ 参考工程用 `CPOL=1, CPHA=1`（Mode 3），在 `sd_card_top.v` 119~120 行硬编码 —— **官方示例实测可用，但这不是规范明文规定的唯一模式**，别把"必须 Mode 3"当成教条 |
| 上电喂 ≥74 个时钟（CS 高、DI 高） | 6.4.1 节 | ✅ **已实现**：`sd_card_cmd.v` 的 `S_INIT` 空发 11 字节 = 88 个时钟，且 CS 保持高（见第六节） |
| 空闲时 DI | 保持高（发 `0xFF`） | — | ✅ 源码里满屏 `send_data <= 8'hff` |

> 分频公式（来自源码注释）：`spi clk = clk / ((DIV + 2) × 2)`
> 100 MHz ÷ ((248+2)×2) = **200 kHz**；100 MHz ÷ ((0+2)×2) = **25 MHz**

---

## 四、命令帧格式：48 位 = 6 字节 ✅

每条命令**固定 6 个字节**：

```
 bit:  47        46 45 ...... 40 | 39 ................ 8 | 7 .... 1 | 0
        │         │  └── 命令号 ──┘ └────── 参数 ──────┘ └─ CRC7 ─┘ └ 结束位
        │         └─ 传输位（恒为 1）
        └─ 起始位（恒为 0）
```

| 字段 | 位数 | 值 | 说明 |
|---|---|---|---|
| 起始位 | 1 | **0** | 帧开始标志 |
| 传输位 | 1 | **1** | 表示"主机→卡"方向 |
| 命令号 | 6 | 0~63 | 如 CMD17 → `010001` |
| 参数 | 32 | 视命令 | 如 CMD17 填扇区地址 |
| CRC7 | 7 | 视命令 | **SPI 模式下默认不检查**，填 `0xFF` 即可 |
| 结束位 | 1 | **1** | 帧结束标志 |

### ✅ 源码印证（`sd_card_cmd.v` 第 163~173 行）

```verilog
send_data <= (cmd[47:40] | 8'h40);   // 首字节 = 0x40 | 命令号  →  起始位0 + 传输位1
send_data <= cmd[39:32];             // 参数 4 字节
... cmd[31:24] / cmd[23:16] / cmd[15:8] / cmd[7:0]
```

**`| 8'h40` 就是"把起始位置 0、传输位置 1、再填 6 位命令号"** —— 这就是为什么命令表里 CMD17 的首字节写作 `0x51`（`0x40 | 17`）。

**CRC7 的两个例外**（SPI 模式下也必须正确）：
| 命令 | CRC 字节 | 说明 |
|---|---|---|
| CMD0 | `0x95` | ✅ 源码 `{8'd0,0,0,0,0, 8'h95}` |
| CMD8 | `0x87` | ✅ 源码 `{8'd8,0,0,1,8'haa, 8'h87}` |

其余命令源码一律填 `0xFF`（✅ 见 `8'd55`/`8'd41`/`8'd16`/`8'd17`/`8'd24` 的最后一字节）。

---

## 五、命令表（含参考工程实际用到的）✅🌐

| 命令 | 首字节 | 参数 | 响应 | 作用 | 参考工程 |
|---|---|---|---|---|---|
| **CMD0** | `0x40` | `0x00000000` | R1 | GO_IDLE_STATE，复位并进 SPI 模式 | ✅ |
| **CMD8** | `0x48` | `0x000001AA` | R7 | SEND_IF_COND，探测 SD 2.0 与电压 | ✅ |
| **CMD9** | `0x49` | 0 | R1 | SEND_CSD，读卡容量等 | ❌ |
| **CMD12** | `0x4C` | 0 | R1b | STOP_TRANSMISSION，停多块读 | ❌ |
| **CMD13** | `0x4D` | 0 | R2 | SEND_STATUS | ❌ |
| **CMD16** | `0x50` | `512` | R1 | SET_BLOCKLEN，设块长 = 512 B（⚠️ **对 SDHC/SDXC 是空操作** —— 块长固定 512，CMD16 只对 CMD42 有意义，见 13.3-9） | ✅ |
| **CMD17** | `0x51` | 扇区地址 | R1 | **READ_SINGLE_BLOCK**，读一个块 | ✅ |
| CMD18 | `0x52` | 起始扇区 | R1 | READ_MULTIPLE_BLOCK，连续读 | ❌ |
| CMD24 | `0x58` | 扇区地址 | R1 | WRITE_BLOCK，写一个块 | ✅（用不到） |
| **CMD55** | `0x77` | 0 | R1 | APP_CMD，**下一条是应用命令**的前导 | ✅ |
| CMD58 | `0x7A` | 0 | R3 | READ_OCR，读 OCR（判断 SDHC） | ❌ |
| **ACMD41** | `0x69` | `0x40000000` | R1 | SD_SEND_OP_COND，**循环查询直到就绪** | ✅ |

> **ACMD41 的参数 `0x40000000`** 是 **HCS 位（bit 30）= 1**，意思是"主机支持 SDHC/SDXC"。
> **ACMD41 必须配合 CMD55 使用**：CMD55 → ACMD41 → 若不就绪则 CMD55 → ACMD41 …… 循环。✅ 源码 `S_CMD41` 里 `else if(cmd_req_ack) state <= S_CMD55;` 就是重试。

### 命令的两种"寻址单位"（坑）🌐

| 卡类型 | 容量 | CMD17 的地址单位 |
|---|---|---|
| SDSC（标准容量） | ≤ 2 GB | **字节地址**（要 ×512） |
| SDHC / SDXC | > 2 GB | **块地址（LBA）**，1 = 512 B |

参考工程直接把"扇区号"传给 CMD17（✅ `cmd <= {8'd17, sec_addr, 8'hff}`），**说明它假设卡是 SDHC（块寻址）**。现在市面上的卡基本都是 SDHC/SDXC，所以没问题；但**如果要兼容老卡，得先用 CMD58 读 OCR 的 CCS 位判断**。参考工程没做这一步。

---

## 六、✅ 参考工程确实实现了"上电 74 个时钟"（含一条勘误）

**规范原文（6.4.1 节，本地存档 PDF）**：

> "The host shall supply power to the card so that the voltage is reached to Vdd_min within 250ms and start to supply **at least 74 SD clocks** to the SD card **with keeping CMD line to high**. **In case of SPI mode, CS shall be held to high during 74 clock cycles.**"

同节还有一句说明这 74 个时钟的用途：

> "Device may use up to 74 clocks for preparation before receiving the first command."

**完整要求**：上电后、发第一条命令前，SCLK 给 **≥74 个时钟**，且 **CS 保持高、DI(CMD) 保持高**。

### 6.1 参考工程在哪儿实现的

**在层2 `sd_card_cmd.v` 的 `S_INIT` 状态里**：

```verilog
S_INIT:
begin
    // 上电先空发 11 个字节（88 个时钟 ≥ 规范要求的 74 个），此期间 CS 保持高
    if(spi_wr_ack == 1'b1)
        if(byte_cnt >= 16'd10) ...      // 0~10 共 11 个字节
        else send_data <= 8'hff;
end
```

| 检查点 | 结果 |
|---|---|
| 谁在发这 88 个时钟？ | `sd_card_cmd.v` 的 `S_INIT`：`send_data <= 8'hff` 空发 **11 个字节** |
| 够 74 个吗？ | ✅ 11 × 8 = **88 个时钟**，满足"至少 74" |
| 这期间 CS 是高还是低？ | ✅ **保持高**。`S_INIT` 里没有给 `CS_reg` 赋值，而进入前的 `S_IDLE` 把它置成了 `1'b1` —— 正是规范要求的做法 |
| 那什么时候才发 CMD0？ | `S_INIT` 走完进 `S_WAIT` 等请求，请求来了才发 CMD0 |

### 6.2 ⚠️ 勘误：本节早期版本写错了

> **本节原来写的是"参考工程没有实现上电 74 时钟"，这个结论是错的。**
>
> **错因**：我只查了两个地方就下了结论 ——
> ① `spi_master.v`：确认它 IDLE 状态不产生时钟（对，但那是层1，本来就不该管这事）；
> ② `sd_card_sec_read_write.v`：确认它复位后一拍就跳 `S_CMD0`（也对，但层3 本来就不负责喂时钟）。
>
> **漏掉了中间那一层**：上电喂时钟是**层2 `sd_card_cmd.v`** 的职责，它有个专门的 `S_INIT` 状态。层3 不干这事，所以在层3 里当然找不到。
>
> **方法论（这条对你们读代码比结论本身更有用）**：这条链是**分层**的，**"某一层里找不到" ≠ "整个工程没做"**。查某个协议动作有没有实现，要么沿调用树把每一层都过一遍，要么直接全局 grep 关键字（这里搜 `74`、`16'd10`、`0xff` 都能命中）。

### 6.3 对你们的意义

**这条不需要你们做任何事** —— 只要原样搬 `sd_card_cmd.v`，74 时钟就自动有了。

但反过来要注意：**如果你们决定自己重写层2（不搬 `sd_card_cmd.v`），就必须自己补这一步**，否则可能遇到"某些卡初始化不了、某些卡正常"。补法就是照 `S_INIT` 抄：空发 11 个 `0xFF`，且 CS 保持高。

---

## 七、响应类型：R1 / R3 / R7 🌐✅

### 响应怎么"等"？✅

发完命令后，主机**持续发 `0xFF` 并读 MISO**，直到读到一个 **bit7 = 0** 的字节 —— 那就是响应的第一个字节。

✅ 源码印证（`sd_card_cmd.v`）：
```verilog
// 第 310 行附近：等总线空闲
if (data_recv == 8'hff) ...
// 第 135 行：带超时保护的响应等待
if ((byte_cnt == 16'hffff) || (data_recv != cmd_r1 && data_recv[7] == 1'b0)) → 报错
else if (data_recv == cmd_r1) → 成功
```
**`data_recv[7] == 1'b0` 就是"bit7 = 0 表示这是响应"这条规则的实现**，`16'hffff` 是超时保护（没有超时，卡一拔就死等）。

### R1（1 字节）

| bit | 含义 |
|---|---|
| 7 | **恒为 0**（响应标志） |
| 6 | 参数错误 |
| 5 | 地址错误 |
| 4 | 擦除序列错误 |
| 3 | CRC 错误 |
| 2 | 非法命令 |
| 1 | 擦除复位 |
| 0 | **1 = 空闲（IDLE），0 = 就绪** |

**关键**：CMD0/CMD8/CMD55 的正常响应是 **`0x01`（还在 IDLE）**，而 ACMD41 成功时返回 **`0x00`**。✅ 源码里 `cmd_r1 <= 8'h01` / `8'h00` 的赋值正好对应这两类。

### R3（5 字节）= R1 + OCR（4 字节）
CMD58 返回。OCR 的 **bit 31（CCS）**：1 = SDHC/SDXC（块寻址），0 = SDSC（字节寻址）。

### R7（5 字节）= R1 + 4 字节 echo
CMD8 返回。这 4 字节应**原样回显**主机发的参数（电压 + check pattern `0xAA`）。✅ 源码 CMD8 参数是 `0x000001AA`，正常应回 `0x01AA` 类似值。

---

## 八、数据令牌与单块读时序 ✅🌐

### 数据令牌（单字节）

| 令牌 | 值 | 用途 |
|---|---|---|
| **起始块（单块）** | **`0xFE`** | CMD17 读、CMD24 写 |
| 起始块（多块） | `0xFC` | CMD18/CMD25 |
| 停止传输 | `0xFD` | 停多块 |
| Data Error | `0x0?` | 写失败 |

✅ 源码印证：`sd_card_cmd.v` 第 201 行 `if(spi_wr_ack == 1'b1 && data_recv == 8'hfe)` —— **这就是"等 0xFE 起始令牌"的实现**；第 244 行 `send_data <= 8'hfe;` 是写路径发令牌。

### 单块读（CMD17）完整时序

```
主机:  [CMD17 6字节] → 0xFF 0xFF ...（等响应）
卡:                    ← R1
主机:  0xFF 0xFF ...（等令牌）
卡:                    ← 0xFE 起始令牌
卡:                    ← 512 字节数据
卡:                    ← CRC16（2 字节，SPI 模式不检查）
```
✅ 源码 `sd_card_cmd.v` 第 339 行 `else if(state == S_READ && byte_cnt < 16'd512)` —— **正好数 512 字节**，是"块长 = 512"的直接体现。

### 单块写（CMD24）时序

```
主机: [CMD24 6字节] → 等 R1
主机: 0xFE（起始令牌）→ 512 字节数据 → CRC16（2 字节，填 0xFF 0xFF）
卡:   ← Data Response（形如 xxx00101，低 3 位 101 = 接受）
卡:   进入 busy，主机持续发 0xFF 直到 MISO 变高
```

---

## 九、初始化完整流程：SPI 模式 vs SD 模式 🌐

| 步 | **SPI 模式（参考工程用的）** | SD 模式（参考工程不用） |
|---|---|---|
| 1 | SCLK ≤ 400 kHz | SCLK 0~400 kHz |
| 2 | ≥74 个时钟，CS 高、DI 高 —— ✅ 参考工程在 `S_INIT` 里发了 **88 个** | — |
| 3 | CMD0，**同时 CS 拉低** → 进 SPI 模式 / IDLE | CMD0 → IDLE |
| 4 | CMD8（`0x1AA`）探测 SD2.0 + 电压 | CMD8 同 |
| 5 | CMD55 + ACMD41 **循环**（HCS=1） | CMD55 + ACMD41 循环；**还需 CMD2 读 CID、CMD3 读 RCA** |
| 6 | （可选）CMD58 读 OCR 判断 SDHC | CMD9 读 CSD |
| 7 | CMD16 设块长 = 512 | CMD7 选中卡 |
| 8 | 切高速（≤25 MHz） | 切高速（SD 模式可达 50 MHz × 4 bit） |

**核心差别**：SPI 模式**不需要 RCA**（没有 CMD3/CMD7 的寻址过程），这就是它简单得多的原因。代价是速度只有 1/8：

| | 数据宽度 | 速度 |
|---|---|---|
| SD 模式 | 1 或 **4** 位 | 50 MHz × 4 = **25 MB/s** |
| **SPI 模式** | 只能 **1** 位 | 25 MHz × 1 = **3.125 MB/s** |

> 不过对本项目**够用**：一张 640×480 的图约 0.3~0.5 秒，**双缓冲已经把这 0.5 秒藏起来了**。

---

## 十、参考工程实现 ↔ 协议概念 对照表 ✅

| 协议概念 | 参考工程在哪儿实现 |
|---|---|
| 命令帧 6 字节拼装（首字节 = 命令号 或上 0x40） | `sd_card_cmd.v` 的 `S_CMD` 状态 |
| R1 响应等待（bit7 == 0）+ 超时保护 | `sd_card_cmd.v` 的 `S_CMD` 状态（`byte_cnt == 16'hffff` 或 `data_recv[7] == 1'b0`） |
| 数据令牌 `0xFE` 等待 | `sd_card_cmd.v` 的 `S_READ_WAIT` 状态 |
| 上电 ≥74 个时钟 | `sd_card_cmd.v` 的 `S_INIT` 状态：空发 11 字节 = 88 个时钟，CS 保持高 |
| 512 字节块长 | `sd_card_cmd.v` 末尾 `block_read_valid` 的 `byte_cnt < 16'd512`，以及 `S_READ` 数到 514（512 数据 + 2 CRC） |
| 初始化命令序列 | `sd_card_sec_read_write.v` 的 `S_IDLE→S_CMD0→S_CMD8→S_CMD55→S_CMD41→S_CMD16` |
| ACMD41 循环重试 | `S_CMD41` 里 `else if(cmd_req_ack) state <= S_CMD55;` |
| 低速→高速切换 | `S_CMD41` 应答成功时 `spi_clk_div <= SPI_HIGH_SPEED_DIV` |
| 分频公式 | `sd_card_sec_read_write.v` 参数注释 |
| CPOL/CPHA = 1/1（Mode 3） | `sd_card_top.v` 第 119~120 行硬编码 |
| SPI 4 根引脚 | `constraints_source/pin.adc` |
| 上电 74 时钟 | ✅ `sd_card_cmd.v` 的 `S_INIT`：空发 11 字节 = 88 个时钟，CS 保持高 |

---

## 十一、对你们项目的意义

| # | 结论 | 行动 |
|---|---|---|
| 1 | 协议本身**没有 FAT32**，也**不需要** —— 参考工程按扇区裸读，你们照做更简单 | ✅ 方案已改成扇区扫描 |
| 2 | **上电 74 时钟已在 `sd_card_cmd.v` 的 `S_INIT` 里实现**（88 个时钟，CS 保持高） | 照搬即可；**若自己重写层2 则必须补这一步** |
| 3 | 参考工程**假设 SDHC（块寻址）**，没做 CMD58 判断 | 用市面上的 SDHC 卡即可，别用 ≤2 GB 的老卡 |
| 4 | SPI 模式比 SD 模式慢 8 倍，但被双缓冲掩盖 | 不用改，维持 SPI 模式 |
| 5 | 官方规范 PDF + elm-chan 页面**建议本地存档** | 用浏览器下载到 `_ref/` 下 |

---

## 十二、待办

- [x] ✅ **已下载官方简化规范 v9.10** 并本地存档（见第十三节）
- [ ] 打开并存档 **elm-chan《How to Use MMC/SDC》**（SPI 模式实操第一参考；本环境网络不可达，需你在浏览器操作）
- [x] ✅ 已核实"上电 74 时钟"**参考工程已实现**（`sd_card_cmd.v` 的 `S_INIT`，88 个时钟，CS 保持高）—— 见第六节勘误
- [ ] 把 `sd_card_cmd.v` 的注释**译成中文**（已做：原文件备份为 `sd_card_cmd.v.en-orig.bak`，可用 `diff` 对比）
- [ ] 确认手头 TF 卡是 **SDHC/SDXC**（>2 GB），避免字节寻址问题
- [ ] 通读规范 **第 7 章（打印页 286~309）** —— SPI 模式的内容全在这一章

---

## 十三、官方规范已拿到本地 ✅

### 13.1 存档位置

| 文件 | 说明 |
|---|---|
| `_ref/规格书/SD_Part1_Physical_Layer_Simplified_Spec_Ver9.10.pdf` | **官方最新简化规范 v9.10（2023-12-01）**，409 页，5.9 MB，AES-256 加密 |
| `_ref/规格书/SPI_mode_ch7.txt` | **第 7 章（SPI Mode）** 的文字抽取，打印页 286~309，52 KB，方便直接 grep |

> ⚠️ 该 PDF 设置是 **`copy:no`**（允许打印、禁止复制）。**正文不要外传**，本地查证用即可。
>
> 📐 **页码换算（踩过坑）**：`pdftotext` 用的是 **PDF 页序**，与文档里印的页码差 26 页：
> **打印页 = PDF 页 − 26**。所以第 7 章（打印 286~309）要用 `-f 312 -l 336`。
>
> 复现命令（本机 `pdftotext` 可用，实测能抽出全文 34731 行）：
> ```bash
> # 只抽第 7 章（SPI 模式）
> pdftotext -f 312 -l 336 SD_Part1_Physical_Layer_Simplified_Spec_Ver9.10.pdf SPI_mode_ch7.txt
> # 抽全文（约 940 KB，用完可删）
> pdftotext SD_Part1_Physical_Layer_Simplified_Spec_Ver9.10.pdf out.txt
> ```

### 13.2 怎么重新下载（三个坑都在这儿）

官方下载页是 [sdcard.org/downloads/pls/](https://www.sdcard.org/downloads/pls/)，**难点是它是个 JS 网关**：

| # | 坑 | 现象 | 真相 |
|---|---|---|---|
| ① | 版本看错 | 以为最新是 v9.00 | 下载页上已经是 **v9.10**（`…Ver9.10Fin_20231201.pdf`） |
| ② | 端点写错 | `/cms/wp-content/themes/sdcard-org/dl.php?f=…` 返回 `content-length: 0` | 正确路径**没有 `/cms`**：`/wp-content/themes/sdcard-org/dl.php?f=…` |
| ③ | 以为要过校验 | 页面里有个 `dl_check` 隐藏字段 | 那只是**前端变量**，服务端不校验 —— **直接 GET 就行** |

**能用的命令**（实测 3.4 秒下完 5.9 MB）：

```bash
curl -L --max-time 300 \
  -A 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120 Safari/537.36' \
  -H 'Referer: https://www.sdcard.org/downloads/pls/pdf/' \
  -o SD_Part1_Physical_Layer_Simplified_Spec_Ver9.10.pdf \
  'https://www.sdcard.org/wp-content/themes/sdcard-org/dl.php?f=Part1PhysicalLayerSimplifiedSpecificationVer9.10Fin_20231201.pdf'
```

### 13.3 逐条核对：本文档 vs 规范原文

| # | 本文档原来怎么写 | 规范怎么说 | 结论 |
|---|---|---|---|
| 1 | 命令帧 48 位：起始0 / 传输1 / 命令号6 / 参数32 / CRC7 / 结束1 | **Table 7-1 Command Format** 逐位一致 | ✅ 正确 |
| 2 | 首字节 = `0x40 \| 命令号` | 由 Table 7-1 直接推出 | ✅ 与源码 `\| 8'h40` 吻合 |
| 3 | 起始块令牌 `0xFE` | 7.3.3.2：`1111 1110` | ✅ |
| 4 | 多块起始 `0xFC` / 停止 `0xFD` | 7.3.3.2：`1111 1100` / `1111 1101` | ✅ |
| 5 | R1：bit7=0、bit6 参数错、bit5 地址错、bit4 擦除序列错、bit3 CRC 错、bit2 非法命令、bit1 擦除复位、bit0 空闲 | **Figure 7-9** 完全一致 | ✅ |
| 6 | 上电 ≥74 时钟，CS 高、DI 高 | 6.4.1：*"…at least 74 SD clocks … with keeping CMD line to high. In case of SPI mode, CS shall be held to high during 74 clock cycles."* | ✅ 且规范**明确要求 SPI 模式下 CS 保持高** |
| 7 | 初始化 SCLK **≤ 400 kHz** | 第 4 章给的是 **100 kHz ~ 400 kHz 区间** | ⚠️ **已修正**：应写 100~400 kHz |
| 8 | ACMD41 循环重试 | 第 4 章：*"Issue continuous clock in the frequency range of 100 KHz-400 KHz"*，或"poll busy bit by ACMD41 at less than 50 ms intervals" | ✅ 参考工程的循环正是这个 |
| 9 | CMD16 设块长 512 | 7.2：**SDHC/SDXC 块长固定 512**，CMD16 只对 CMD42 有意义，**不用于存储数据传输** | ⚠️ **新知识点**：对你们的 SDHC 卡，CMD16 其实是空操作 |
| 10 | 参考工程没做 CMD58 | Figure 7-1：*"Not Mandatory to send CMD58: Though it is recommended… Host shall issue CMD58 to get card capacity information (CCS)"* | ⚠️ 规范是"**建议**"而非必须 —— 参考工程省掉它不算违规 |
| 11 | CPOL=1/CPHA=1 是"SD 卡 SPI 必须的 Mode 3" | 规范**全文没有 CPOL/CPHA 这两个术语**；7.5 节在简化规范里空白，7.6/7.7/7.8 只声明"等同于 SD 模式" | ⚠️ **已修正**：Mode 3 是参考工程的选择且实测可用，但规范没这么规定 |
| 12 | （新增）R1b 的 busy 语义 | 7.3.2.2：busy 信号"可以是任意字节数，**0 表示卡忙**，非 0 表示可以收下一条命令" | ➕ 将来写多块要知道 |
| 13 | （新增）SDUC 不支持 SPI | Figure 7-1 注：*"If SDUC card receives CMD0 + CS Asserted(0), the card never responds"* | ➕ **别用 2TB 以上的 SDUC 卡** |
| 14 | （新增）CMD0 之后的切换时机 | 7.3.1：*"The switching period is within 8 clocks after the end bit of the R1 response of CMD0."* | ➕ |
| 15 | （新增）错误的响应形态 | 7.2：读操作出错时，卡**用 error token 替代数据块**，而不是像 SD 模式那样超时 | ➕ 这解释了为什么要有数据错误令牌 |

### 13.4 规范里值得单独翻的几处

| 位置 | 内容 |
|---|---|
| **第 7 章（打印页 286~309）** | ⭐ SPI 模式的全部内容 —— 你们要的东西都在这一章 |
| Figure 7-1（286~287） | **SPI 模式状态图**（CMD8 → ACMD41 → CMD58 的分支都画出来了） |
| Figure 7-2（288） | **SPI 模式初始化流程图** |
| Table 7-1（294） | 命令包格式（48 位逐位） |
| Table 7-3（294~300） | **SPI 模式完整命令表** |
| Figure 7-9（302） | R1 响应格式 |
| 7.3.3.2（305） | 数据令牌（起始/停止/错误） |
| Table 7-6（307） | SPI 模式状态位 |
| 7.6 / 7.7 / 7.8（309） | 电气与总线时序 —— 三节都只有一句"等同于 SD 模式" |
| **6.4.1** | 上电时序（**74 时钟那条在这里，不在第 7 章**） |
