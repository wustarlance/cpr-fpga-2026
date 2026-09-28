# 第7站：`top_tf_hdmi_audio.v` —— 顶层（收口）

> 文件：`src/user_source/hdl_source/top_tf_hdmi_audio.v`（**411 行**）
> ⚠️ **本站不要逐行读**。411 行里绝大部分是"接线"，没有算法
> 💡 **前置**：这是收口的一站 —— 前面 6 站攒的所有零件，在这里被连成一台机器

---

## 〇、先给骨架

### 骨架 1：一句话心智模型 —— 顶层 = **配电房 + 总装接线图**

> | 角色 | 对应 | 干什么 |
> |---|---|---|
> | **配电房** | **PLL + 复位分配** | 造出各种"电压/频率"（时钟），并决定全厂什么时候能开工（复位） |
> | **总装接线图** | **模块例化 + 端口连接**（占 411 行的绝大多数） | 把 5 个车间按**物流顺序**连起来 |
> | （顶层自己**不做加工**） | 只有**几条 `assign`** | 顶层几乎没有算法逻辑 —— 这是好设计，不是偷懒 |

**为什么顶层要"不做加工"？** 因为顶层的职责是**集成**，不是**实现**。一旦某个算法逻辑写进顶层，它就没法被单独仿真、单独复用了。判断一个顶层写得好不好，有一条很实用的标准：**把顶层所有的 `assign` 和 `always` 数一数，越少越好。**

### 骨架 2：顶层只有**四类句子**（这是"怎么读"的策略）

| 类型 | 大概占多少行 | 你要看什么 |
|---|---|---|
| ① **`parameter` / 端口声明** | ~110 | **有哪些可调项、对外接口是什么** |
| ② **PLL 例化** | ~25 | **各路时钟从哪来、频率是多少** |
| ③ **模块例化 + 端口连接** | ~250 | **按数据流一段一段看谁连谁**（本站第五节） |
| ④ **`assign` / `always`（胶水逻辑）** | ~10 | **少数几个"顶层才该做"的事**（本站第六节） |

**所以 411 行里真正需要动脑的，只有大约 35 行**（②③里决定"连法"的部分 + 全部的 ④）。

### 骨架 3：正确的阅读顺序（**不要从第 1 行往下读**）

```
第 1 步  看端口（第 2~26 行）      → 这块板对外是什么形态？
第 2 步  看参数（第 28~33 行）     → 哪些东西可以调？
第 3 步  看时钟（第 117~140 行）   → 有几个时钟域？谁快谁慢？
第 4 步  看复位（第 114 行）        → 什么时候开始工作？
第 5 步  按数据流走 8 段（第五节）  → 货从哪进、经过谁、从哪出
第 6 步  回头看那几条 assign        → 顶层"额外补"了哪些逻辑
```

> 这个顺序的意义：**先建立"这是一台什么机器、有几个节拍"的整体印象，再去看零件怎么摆**。反过来（从第 1 行顺着读）会在前 110 行的信号声明里迷路 —— 那些 `wire` 声明只有当你知道它们要连到哪里时才有意义。

---

## 一、顶层的职责边界：它到底该管什么

`top` 的端口（第 2~26 行）就是**整块板的对外形态**：

| 分组 | 端口 | 说明 |
|---|---|---|
| **时钟/复位** | `clk`, `rst_n` | ⚠️ 见下面第 8 节的细节 1 |
| **按键** | `key1`, `key2` | 手动下一张 / 自动播放开关 |
| **数码管** | `seg_sel[5:0]`, `seg_data[7:0]` | 6 位扫描 + 8 段（7 段 + 小数点） |
| **HDMI（TMDS）** | `HDMI_CLK_P`、`HDMI_D0_P`~`HDMI_D2_P` | 4 对差分（时钟 + 3 个数据通道） |
| **HDMI（DDC）** | `HDMI_DDC_SCL`（输出）、`HDMI_DDC_SDA`（**inout**） | I²C，用来读显示器的 EDID |
| **TF 卡（SPI）** | `sd_ncs`/`sd_dclk`/`sd_mosi`/`sd_miso` | 第5站那 4 根线 |

**对应的实际管脚**（来自 `pin.adc`，✅ 已核）：

| 端口 | 管脚 | 备注 |
|---|---|---|
| `clk` | **R7** | 板载 50 MHz（SDC 里 `create_clock -period 20` = 50 MHz） |
| `rst_n` | **A2** | ⚠️ **这是板载 4 个按键之一**！按它 = 复位 |
| `key1` | **B2** | 板载按键 |
| `key2` | **C1** | 板载按键 |
| （未用） | **B1** | 板载第 4 个按键，**本工程没用** |
| `sd_*` | A12 / A14 / A13 / B14 | 第5站已核实 |
| HDMI TMDS | C3 / G5 / F1 / E1 | LVDS33 |
| HDMI DDC | P2 / R2 | 带 PULLUP |

> **顶层该管的四件事**（也是本站的四条主线）：
> ① 参数集中管理 ② 造时钟 ③ 管复位 ④ 接线
> **顶层不该管的**：任何"业务"（比如"按键按了要干什么" —— 那是 `sd_card_bmp` 的事）

---

## 二、第①类：参数表（第 28~33 行）

```verilog
parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;              // ⚠️ 拼写错误，见第九节
parameter FRAME_PIXELS  = 24'd307200;   // 640*480
parameter BUF0_ADDR     = 24'd0;
parameter BUF1_ADDR     = FRAME_PIXELS;      // = 307200
```

**为什么这些要放顶层？** 因为它们是**跨模块的公共常量**，多个模块必须拿到同一个值：

| 参数 | 谁在用 | 不一致会怎样 |
|---|---|---|
| `FRAME_PIXELS` | `frame_read_write` 的 `read_len` / `write_len` | 写一帧的像素数和"一帧多少像素"定义不一致 → 图像截断/错位 |
| `BUF0_ADDR` / `BUF1_ADDR` | `frame_read_write` 的 read/write 各 4 组地址 | 双缓冲的两块区域重叠 → 边写边显示同一块 → 撕裂 |
| `ADDR_BITS = 21` | SDRAM 地址宽度 | `2^21 = 2M 个字 × 4 B = 8 MB`，**正好等于片内 SDRAM 容量**（不是随便定的） |

### ★ 核对表 1：缓冲区地址

| 项 | 值 | 核对 |
|---|---|---|
| `BUF0_ADDR` | `0` | ✅ |
| `BUF1_ADDR` | `307200` = 640 × 480 | ✅ |
| 两块是否重叠？ | 第 0 块占 `[0, 307199]`，第 1 块占 `[307200, 614399]` | ✅ 不重叠 |
| 总占用 | `614400 个字 = 2.4 MB`（片内 8 MB） | ✅ 余量充足（还能再放 2 块 —— 这也解释了为什么 4 组地址是"预留"的） |

### ★ 核对表 2：HDMI 视频时序（第 348~359 行）

```verilog
.HTOTAL(800) .HSA(96) .HFP(16) .HBP(48) .HACTIVE(640)
.VTOTAL(525) .VSA(2)  .VFP(10) .VBP(33) .VACTIVE(480)
.VIDEO_VIC(1) .VIDEO_FORMAT("RGB") .AUDIO_SAMPLE_RATE("48K")
```

**逐项验算**（这是能自己推的，推过一遍就忘不掉）：

```
水平：HACTIVE + HSA + HFP + HBP = 640 + 96 + 16 + 48 = 800 = HTOTAL ✅
垂直：VACTIVE + VSA + VFP + VBP = 480 +  2 + 10 + 33 = 525 = VTOTAL ✅
```

| 项 | 值 | 单位 | 含义 |
|---|---|---|---|
| `HACTIVE`/`VACTIVE` | 640 / 480 | 像素 | **有效**区域（真正显示的部分） |
| `HSA` | 96 | 像素 | 行同步脉冲宽度（HSync 低电平持续多久） |
| `HFP` | 16 | 像素 | 行**前**肩（同步脉冲**之前**的空闲） |
| `HBP` | 48 | 像素 | 行**后**肩（同步脉冲**之后**的空闲） |
| `VSA` | 2 | 行 | 场同步脉冲宽度 |
| `VFP`/`VBP` | 10 / 33 | 行 | 场前肩 / 场后肩 |
| `VIDEO_VIC` | 1 | — | CEA-861 的"视频标识码"：**VIC 1 = 640×480p@60** |
| `VIDEO_FORMAT` | `"RGB"` | — | 像素编码格式 |
| `AUDIO_SAMPLE_RATE` | `"48K"` | — | 音频采样率（和 ACR 的 N 配套，见第五节 7 段） |

> 📌 这些数字就是**第1站 `video_timing_data.v` 里 `video_define.v` 宏定义的同一套**（那里是产生时序的模块，这里是告诉 HDMI 核"时序长这样"）。**两处必须一致** —— 这就是为什么最该放到顶层集中管理。
>
> 📚 **外部参考**：VIC 表的权威出处是 **CEA-861** 标准（`VIC 1 = 480p_60 640`，见参考 [2]）。注意标准里 640×480p60 的像素时钟是 **25.175 MHz**，本工程用的是 **25.000 MHz** —— 见第八节细节 1。

---

## 三、第②类：时钟树（第 117~140 行）⭐

**这一节是顶层的第一个核心。** 三个 PLL，每个的输出、频率、去向：

```verilog
sys_pll sys_pll_m0(
    .refclk(clk), .reset(1'b0),
    .clk0_out(sd_card_clk),      // 100 MHz  → TF 卡逻辑
    .clk1_out(ext_mem_clk),      // 125 MHz  → SDRAM / 帧缓存
    .clk2_out(ext_mem_clk_sft)   // 125 MHz 移相 180° → 只喂 SDRAM 芯片的时钟脚
);
video_pll video_pll_m0(
    .refclk(clk), .reset(1'b0),
    .clk0_out(video_clk),        //  25 MHz  → 显示时序 / HDMI 像素时钟
    .clk1_out(hdmi_5x_clk)       // 125 MHz  → TMDS 串行时钟（= 5 × 25 MHz）
);
PLL_HDMI_AUDIO u_audio_pll(
    .refclk(clk), .reset(1'b0), .extlock(audio_pll_lock),
    .clk0_out(),                 // ⚠️ 75 MHz  —— 未连接
    .clk1_out(),                 // ⚠️ 375 MHz@90° —— 未连接
    .clk2_out(audio_mclk)        // 12.288 MHz → 音频主时钟
);
```

### 3.1 完整时钟表（含"生成但没用"的）

| 时钟 | 频率 | 谁产生 | 用在哪 | 域的含义 |
|---|---|---|---|---|
| `clk` | **50 MHz** | 板载晶振（R7） | 3 个 PLL 的参考 + 数码管扫描 | 原始参考 |
| `sd_card_clk` | **100 MHz** | sys_pll clk0 | TF 卡 SPI 链路（第5站四层 + `sd_card_bmp`） | **SD 域** |
| `ext_mem_clk` | **125 MHz** | sys_pll clk1 | `frame_read_write` 的 mem_clk + `sdram` | **存储域** |
| `ext_mem_clk_sft` | 125 MHz，**移相 180°** | sys_pll clk2 | **只接 `sdram` 的 `Clk_sft`** | 见下 |
| `video_clk` | **25 MHz** | video_pll clk0 | 显示时序、`video_delay`、HDMI 核、`I2S_receiver`、`audio_arc_calculate` | **显示域** |
| `hdmi_5x_clk` | **125 MHz** | video_pll clk1 | `hdmi_phy_wrapper` 的串行时钟 | 见下 |
| `audio_mclk` | **12.288 MHz** | 音频 PLL clk2 | `hdmi_audio_tone_i2s_64fs` | **音频域** |
| ~~75 MHz~~ | 75.000 MHz | 音频 PLL clk0 | ❌ **未连接**（历史遗留） | — |
| ~~375 MHz~~ | 375.000 MHz @90° | 音频 PLL clk1 | ❌ **未连接**（历史遗留） | — |

**频率是怎么配出来的**（音频 PLL 的 `.ipc` 配置，✅ 已核）：

```
VCO = 750 MHz
  clk0: 750 ÷ 10 = 75.000 MHz
  clk1: 750 ÷  2 = 375.000 MHz
  clk2: 750 ÷ 61 = 12.295 MHz  ≈ 12.288 MHz（目标值，小数分频的近似）
```

### 3.2 两个"为什么用这个频率"

**① `hdmi_5x_clk` 为什么是 5 倍像素时钟？**

TMDS 把每个 8 位像素编码成 **10 位**，用**差分对 + DDR（双沿）**发送。所以：

```
串行位率 = 像素率 × 10（编码）
串行时钟 = 串行位率 ÷ 2（DDR，双沿）= 像素率 × 5
```

**25 MHz × 5 = 125 MHz** ✅ —— 所以叫 `hdmi_5x_clk`。
> 📚 参考 [3]：Intel 的 HDMI 文档里明确写 "Data rate < 1 Gbps → **5× TMDS clock frequency**"。

**② `ext_mem_clk_sft` 为什么要移相 180°？**

它**不驱动任何逻辑**，只接到 SDRAM 芯片的时钟脚。目的是**让 SDRAM 芯片采样的时刻落在数据眼图的中心**（FPGA 输出的数据和时钟之间有 PCB 走线/IO 延迟；把时钟移相 180°，等价于把采样点挪到数据窗口中间，增大裕量）。

**怎么验证它"只喂时钟脚"？** ✅ 看 STA 报告的 fanout：

```
clk6: 125.000   fanout 1   sys_pll_m0/pll_inst.clkc[2]     ← 只有 1 个负载
clk7:  75.002   fanout 0   u_audio_pll/pll_inst.clkc[0]    ← 0 个负载 = 没人用！
```

> ⭐ **这是本节最实用的一招**：**看 STA 时钟表里的 `Fanout` 列，就能发现"生成了但没人用"的时钟**。`fanout 0` 的时钟（如上面 75 MHz 那路）说明顶层接了悬空，白耗 PLL/布线资源。

### 术语卡（时钟）

| 术语 | 意思 |
|---|---|
| **PLL** | 锁相环。输入一个参考时钟，输出若干"倍频/分频/移相"过的时钟 |
| **VCO** | 压控振荡器，PLL 内部的高频源；各路输出都是 VCO 分频得到的 |
| **移相（phase shift）** | 输出时钟相对参考时钟的相位差，用于调整采样时刻 |
| **fanout** | 一个信号驱动多少个负载。**时钟的 fanout = 0 就是没人用** |
| **时钟域（clock domain）** | 由同一个时钟驱动的所有触发器。**跨域必须做同步**（第2站、第5站反复出现） |

---

## 四、第③类：复位树（第 114 行）

```verilog
assign rst_all = ~rst_n | ~audio_pll_lock;
```

**就一行，但信息量很大：**

| 项 | 说明 |
|---|---|
| **谁参与复位** | ① 外部按键 `rst_n`（低有效，所以取反）② **音频 PLL 没锁上**（`audio_pll_lock` 低有效） |
| **复位性质** | **异步、高有效**（因为用在 `always @(posedge clk or posedge rst_all)` 的异步复位端） |
| **一条线走天下** | 全工程所有模块的 `rst` 都接它 —— 好处是简单；坏处见第九节坏味道 |

### ⭐ 一个重要的设计取舍：**只用了一个 PLL 的 lock**

三个 PLL 里**只有音频 PLL 的 `extlock` 被引出并参与了复位**：

| PLL | 有 lock 信号吗 | 参与复位吗 | 如果它没锁上会怎样 |
|---|---|---|---|
| `sys_pll` | ❌ 顶层没引 `extlock` | ❌ | **SD/存储域用着未锁定的时钟照跑** → 行为未定义 |
| `video_pll` | ❌ 同上 | ❌ | **显示域照跑** → 可能显示异常 |
| `PLL_HDMI_AUDIO` | ✅ `.extlock(audio_pll_lock)` | ✅ | 一直复位，不会出坏数据 |

**为什么唯独音频要管？** 因为**音频是"不能被瞬时噪声污染"的** —— 音频通路（`I2S_receiver` + ACR）一旦在时钟不稳时跑起来，会产生错误的采样率信息，有些显示器/功放可能就再也同步不上了。而图像错几帧看不出来。

**这是一个"按后果严重程度决定保护力度"的例子** —— 值得学，但也确实留了隐患（见第九节）。

### 术语卡（复位）

| 术语 | 意思 |
|---|---|
| **同步复位 / 异步复位** | 异步复位一拉就生效（不等时钟）；同步复位要等时钟沿。异步复位写法是 `always @(posedge clk or posedge rst)` |
| **复位释放（release）** | 复位撤销的时刻。异步复位撤销时要和时钟对齐，否则可能亚稳态（进阶话题） |
| **PLL lock** | PLL 输出稳定的指示。**lock 为低时输出时钟不可用** |

---

## 五、第④类：接线 —— 按数据流走 8 段

**这是本站的主体。** 顺着"货从哪进、经过谁、从哪出"走，不要按行号读。

```
                     ┌─────────────── ① 时钟：3 个 PLL ───────────────┐
                     │              ② 复位：rst_all                   │
        ┌────────────┴───────────────────────────────────────────────┴──────────┐
        │                                                                          │
   ┌────▼─────┐   写请求   ┌──────────────┐   App_wr_*   ┌────────┐              │
   │ SD 卡 ③  │ ─────────► │ frame_read_  │ ───────────► │ SDRAM ④│              │
   │sd_card_  │            │ write        │              │  U3    │              │
   │bmp       │            │ （第2站+第6站）│ ◄─────────── │        │              │
   └──────────┘            └──────┬───────┘   Sdr_rd_*   └────────┘              │
        │ display_valid           │ read_en / read_data[31:8]                     │
        │ buf_idx                 ▼                                              │
        │                  ┌──────────────┐   hs/vs/de   ┌──────────────┐         │
        └─────────────────►│ video_delay  │ ───────────► │ RGB→AXIS ⑥   │         │
                           │ （第3站）     │              └──────┬───────┘         │
                           └──────▲───────┘                     │ axis_s_*        │
                                  │ hs_0/vs_0/de_0              ▼                 │
                           ┌──────┴───────┐            ┌──────────────────┐       │
                           │video_timing_ │            │ HDMI 1.4b 发射核 │       │
                           │data（第1站） │            └────────┬─────────┘       │
                           └──────────────┘                     │ TMDS 4 通道    │
                           ┌──────────────┐                     ▼                │
                           │ 音频 ⑦        │            ┌──────────────┐          │
                           │ 测试音→I2S→ACR│ ─────────► │ HDMI PHY     │──► 差分对 │
                           └──────────────┘            └──────────────┘          │
```

### 5.1 段③：SD 卡通道（第 151~178 行）

```verilog
sd_card_bmp #(
    .CLK_FREQ_HZ(100_000_000),   // 与 sd_card_clk 一致（给内部去抖用）
    .SCAN_START_SECTOR(32'd0),   // 从扇区 0 开始扫
    .SCAN_MAX_SECTOR(32'd131071),// 扫到第 131071 个扇区为止
    .SCAN_TARGET_COUNT(3'd4)     // 最多找 4 张图
) sd_card_bmp_m0(
    .clk(sd_card_clk), .rst(rst_all),
    .key_next(key1), .key_auto(key2),
    .state_code(state_code),      // → 数码管
    .bmp_width(16'd640), .bmp_height(16'd480),
    .display_valid(display_valid),  // → 顶层门控（见第六节）
    .write_finish_toggle(frame_write_toggle_mem),  // ← 跨时钟域（见 5.2）
    .write_buf_idx(write_buf_idx), .disp_buf_idx(disp_buf_idx),
    .write_req/ack/en/data(...),   // → frame_read_write 的写侧
    .SD_nCS/sd_ncs, .SD_DCLK/sd_dclk, .SD_MOSI/sd_mosi, .SD_MISO/sd_miso
);
```

**要点**：

| 点 | 说明 |
|---|---|
| **扫描范围** | 从扇区 0 扫到 **131071**（`131072 × 512 B = 64 MB`）—— 它**不解析 FAT32**，是"暴力扫扇区找 `BM` 头"（第4站的重大发现） |
| **`SCAN_TARGET_COUNT = 4`** | 找到 4 张就停 —— 这就是"最多四张图"的由来，也是**你们要改成三组素材时必须动的地方** |
| **`bmp_width/height` 传 640/480** | 与 `bmp_read` 的 `header_match` 精确比较配套（第4站 + BMP 规范） |
| **`key_next`/`key_auto`** | ⚠️ **预习卡猜错了**：按键**已经在顶层接好了**，不需要改顶层（见第七节 Q5） |

### 5.2 段③的配套：跨时钟域把"写完一帧"从 125 MHz 送到 100 MHz（第 142~148 行）⭐

```verilog
// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
always @(posedge ext_mem_clk or posedge rst_all) begin
    if (rst_all)              frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish) frame_write_toggle_mem <= ~frame_write_toggle_mem;
end
```

**为什么不能直接把 `frame_write_finish` 接过去？必须转成 toggle？**

因为**它只有一个时钟周期的宽度，而且是 125 MHz 的**：

```
125 MHz 下一拍 = 8 ns
100 MHz 下一拍 = 10 ns
```

100 MHz 域**每个 10 ns 才看一次**，而信号只在 8 ns 内有效 —— **有相当概率整个脉冲被跳过**（不是"慢一点"，是"完全丢失"）。丢掉的后果：`sd_card_bmp` 永远等不到"写完了"，**双缓冲永远不切换 → 图像卡在第一张**。

**转成 `toggle`（电平翻转）就稳了**：电平会一直保持到 100 MHz 域看见它为止，再用"边沿检测"把翻转还原成一个脉冲。

> ⭐ **这是全工程第三次出现同一种手法**：
> | 位置 | 手法 |
> |---|---|
> | 第2站 `frame_read_write` | 异步 FIFO 跨域 |
> | 第5站 `sd_card_bmp` | `write_finish_toggle` + 三级同步 + 边沿检测 |
> | **第7站（这里）** | **产生 toggle 的另一半** |
>
> **规律**：**慢→快**用 FIFO 或握手；**快→慢的单拍事件**用 **toggle + 边沿检测**。

### 5.3 段④：SDRAM（第 274~289 行）

```verilog
sdram U3(
    .Clk(ext_mem_clk), .Clk_sft(ext_mem_clk_sft), .Rst(rst_all),
    .Sdr_init_done/Sdr_init_ref_vld/Sdr_busy(...),   // 状态
    .App_wr_en/addr/dm/din(...), .App_rd_en/addr(...),// 用户侧（第6站那套）
    .Sdr_rd_en(...), .Sdr_rd_dout(...)               // 读回数据（32 位）
);
```

**注意这里有个"绕"的地方**：`frame_read_write`（第2站）**不是**直接跟 `sdram` 用 `App_*` 连的，中间还有一层：

```
frame_read_write                                        sdram U3
   .App_rd_en/addr  ───────────────────────────────────►  .App_rd_en/addr
   .Sdr_rd_en       ◄───────────────────────────────────  .Sdr_rd_en
   .Sdr_rd_dout     ◄───────────────────────────────────  .Sdr_rd_dout
```

也就是说 **`Sdr_rd_*` 是从 SDRAM 回到 `frame_read_write` 的读数据通路**，而 `App_rd_*` 是发出去的读请求。**两者方向相反**，名字里的 `App` 和 `Sdr` 只是命名习惯，不是"两个不同的东西"。

> ⚠️ **本站不展开**：`sdram.v` 内部是 `sdr_as_ram` + `EG_PHY_SDRAM_2M_32`，还包含刷新、仲裁、初始化。**第6站留下的两个"待确认"（跨行突发怎么处理、读写仲裁谁优先）答案都在那里** —— 那是唯一还没走读的模块。

### 5.4 段⑤：显示通道（第 198~272 行）

```verilog
video_timing_data video_timing_data_m0(     // 第1站
    .video_clk(video_clk), .rst(rst_all),
    .read_req(video_read_req), .read_req_ack(video_read_req_ack),
    .hs(hs_0), .vs(vs_0), .de(de_0)
);

video_delay video_delay_m0(                 // 第3站
    .video_clk(video_clk), .rst(rst_all),
    .read_en(video_read_en),
    .read_data(video_read_data[31:8]),      // ★ 核对表 3
    .hs(hs_0), .vs(vs_0), .de(de_0),        // 输入：未补偿的时序
    .hs_r(hs), .vs_r(vs), .de_r(de),        // 输出：补偿后的时序
    .vout_data(vout_data_raw)
);

assign vout_data = display_valid ? vout_data_raw : 24'd0;   // ★ 胶水逻辑（第六节）
```

**这三行里藏着一个方向的对照，值得看清**：

| 模块 | 时序信号的角色 |
|---|---|
| `video_timing_data` | **产生**方：它从零造出 `hs_0/vs_0/de_0` |
| `video_delay` | **消费 + 重发**方：接收 `hs_0/vs_0/de_0`，**延迟之后**再输出 `hs/vs/de` |

**为什么 `video_timing_data` 输出的名字带 `_0`，而 `video_delay` 输出的不带？** 因为 `_0` 是"**原始、未延迟**"的那一套，不带 `_0` 的是"**已经和像素数据对齐**"的那一套。**命名即含义** —— 这是好习惯（比叫 `hs1/hs2` 清楚得多）。

`frame_read_write` 的例化（第 226~272 行）体现了第2站的"三个时钟域换乘站"：

| 端口 | 接什么 | 属于哪个域 |
|---|---|---|
| `mem_clk` | `ext_mem_clk`（125 MHz） | 存储域 |
| `write_clk` | `sd_card_clk`（100 MHz） | SD 域 |
| `read_clk` | `video_clk`（25 MHz） | 显示域 |
| `read_addr_index` | **`disp_buf_idx`** | 哪一块正在显示 |
| `write_addr_index` | **`write_buf_idx`** | 哪一块正在被写 |
| `read_len` / `write_len` | `FRAME_PIXELS`（307200） | 一帧长 |

### ★ 核对表 3：读数据切片（第 213 行）

```verilog
.read_data(video_read_data[31:8]),
```

| 项 | 值 | 说明 |
|---|---|---|
| SDRAM 一个字的宽度 | **32 位** | `MEM_DATA_BITS = 32` |
| 实际显示需要 | **24 位**（RGB888） | — |
| 取哪 8 位？ | **丢掉低 8 位 `[7:0]`，取 `[31:8]`** | ✅ 与核对表预期一致 |
| 为什么要这么取？ | 因为第4站把 BMP 的 3 个字节拼成了 `{R,G,B}` 放在**高 24 位**：`write_data = {R,G,B,8'b0}` → 取 `[31:8]` 正好得到 RGB | 这是个**闭环**：写入端和读出端的约定必须一致 |

> ⭐ **这就是"核对表"的意义**：它是**跨模块接口约定**。三张表（时序、地址、切片）都是"两个模块之间的合同"，**顶层是唯一能看到合同双方的地方** —— 所以顶层是最适合做这类核对的位置。

### 5.5 段⑥：RGB/DE → AXIS（第 325~336 行）+ EDID 触发（第 338~345 行）

```verilog
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk(video_clk), .I_rst(rst_all),
    .I_vs(vs), .I_de(de), .I_rgb(vout_data),      // 输入：并行的像素 + 时序
    .O_video_user(axis_s_user), .O_video_valid(axis_s_valid),
    .O_video_last(axis_s_last),  .O_video_data(axis_s_data)  // 输出：AXIS 流
);

startup_pulse #(.CNT_MAX(20'd100000)) u_startup_pulse(   // 第0站
    .I_clk(video_clk), .I_rst(rst_all), .O_pulse(edid_trig)
);
```

| 点 | 说明 |
|---|---|
| **为什么要转 AXIS？** | HDMI 发射核的内部接口是 **AXI4-Stream**（`valid/ready/last/data`），而显示通路是"并行像素 + de/vs"。**转换层 = 两种接口风格的桥** |
| **EDID 触发** | `startup_pulse` 的 `CNT_MAX = 100000`，@25 MHz = **4 ms**（第0站算过）→ 上电 4 ms 后打一拍 `edid_trig`，让 HDMI 核通过 DDC（I²C）去读显示器的 EDID |

**术语卡（AXIS）**

| 术语 | 意思 |
|---|---|
| **AXI4-Stream（AXIS）** | 一种"只传数据流、不带地址"的总线协议。四要素：`valid`（我有数据）、`ready`（我能收）、`last`（这是最后一个）、`data` |
| **`valid`/`ready` 握手** | 与手写的 `req/ack` 是同一类思想，但**更容易组合/流水**（总线互连里通用） |
| **EDID** | 显示器里的一段"能力描述"（支持哪些分辨率/时序），主机通过 DDC（I²C）读它 |
| **DDC** | Display Data Channel，HDMI 上的 I²C 通道（`SCL`/`SDA`） |

### 5.6 段⑦：HDMI 发射（第 347~409 行）

```verilog
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE("EG"), .HTOTAL(800), ... , .VIDEO_VIC(1),
    .VIDEO_TPG("Disable"), .VIDEO_FORMAT("RGB"),
    .AUDIO_SAMPLE_RATE("48K"), .IIC_SCL_DIV(250)
) u_hdmi_1_4b_transmitter_core_wrapper( ... );
```

| 参数 | 值 | 含义 |
|---|---|---|
| `VIDEO_TPG` | `"Disable"` | TPG = Test Pattern Generator。**关掉了内部测试图**（所以画面来自我们自己的 AXIS 流） |
| `IIC_SCL_DIV` | `250` | DDC 的 I²C 时钟分频 → 决定读 EDID 的速率 |
| `DEVICE` | `"EG"` | 器件系列（EG4），供核内部选择原语 |

**端口连接里有一个值得注意的"悬空"**：

```verilog
.O_video_locked(),      // ← 悬空，顶层没接
```

`O_video_locked` 是"视频已锁定"的指示 —— **顶层把它丢掉了**。这意味着：**如果 HDMI 核内部没锁定，顶层无从得知**（对比：音频 PLL 的 lock 是被用起来的）。属于"不完整集成"（见第九节）。

然后是 **PHY 层**（第 395~409 行）：

```verilog
hdmi_phy_wrapper #(.DEVICE("EG")) u_hdmi2phy_wrapper(
    .I_pixel_clk(video_clk),      // 25 MHz
    .I_serial_clk(hdmi_5x_clk),   // 125 MHz = 5×
    .I_tmds_channel_0/1/2/clk(...),   // 4 个 10 位 TMDS 通道
    .O_tmds_ch0_p/ch1_p/ch2_p/clk_p(HDMI_D0_P/HDMI_D1_P/HDMI_D2_P/HDMI_CLK_P)
);
```

**这里体现了 3.2 节算过的关系**：`I_serial_clk = 5 × I_pixel_clk`，PHY 内部做 10:1 串行化（DDR）。

### 5.7 段⑧：音频通道（第 291~323 行）—— ⭐ 不是从 SD 卡来的

```verilog
hdmi_audio_tone_i2s_64fs #(
    .PHASE_INC(32'd39370534), .AMP(24'sd2000000)
) u_hdmi_audio_tone_i2s_64fs (
    .I_mclk(audio_mclk),          // 12.288 MHz
    .I_rst(rst_all),
    .O_i2s_BCLK(audio_i2s_bclk), .O_i2s_LRCK(audio_i2s_lrck), .O_i2s_DOUT(audio_i2s_dout)
);

I2S_receiver u_I2S_receiver(       // 注意：用 video_clk = 25 MHz！
    .I_clk(video_clk), .I_rst(rst_all),
    .I_i2s_BCLK/.../DOUT(...),
    .O_audio_valid(audio_valid),
    .O_audio_left_data(audio_left_data), .O_audio_right_data(audio_right_data)
);

audio_arc_calculate #(.ACR_N(6144)) u_audio_arc_calculate(
    .I_clk(video_clk), .I_rst(rst_all),
    .I_audio_valid(audio_valid),
    .O_acr_valid(acr_valid), .O_acr_cts(acr_cts), .O_acr_n(acr_n)
);
```

#### ⭐ 发现 1：音频是**内部产生的**，不是 SD 卡上的音频文件

数据流是：

```
hdmi_audio_tone_i2s_64fs  ──I2S(BCLK/LRCK/DOUT)──►  I2S_receiver  ──►  HDMI 核
   （内部产生）                                        （还原成左右声道）
```

**所以本工程只演示"HDMI 能出声"，播什么不重要。** 这也回答了预习卡 Q4。

#### ⭐ 发现 2：**它不是单音，是一段音阶序列**

我读了那个模块的内部：里面有一张**音符表** `note_inc_lut`：

| `idx` | 音 | 频率 | 相位增量（DDS） |
|---|---|---|---|
| 0 | do **C4** | 261.63 Hz | 23409862 |
| 1 | re **D4** | 293.66 Hz | 26276681 |
| 2 | mi **E4** | 329.63 Hz | 29494578 |
| 3 | fa **F4** | 349.23 Hz | 31248410 |
| 4 | so **G4** | 392.00 Hz | 35075155 |
| 5 | la **A4** | 440.00 Hz | 39370534 |
| 6 | si **B4** | 493.88 Hz | 44191930 |
| 7 | do **C5** | 523.25 Hz | 46819716 |

- `NOTE_HOLD_FRAMES = 24000` → 每个音持续 `24000 ÷ 48000 Hz = **0.5 秒**`
- 用 32 位**相位累加器**（DDS）产生正弦：`S_phase_acc <= S_phase_acc + W_note_inc;`
- **顶层传的 `PHASE_INC = 39370534` 是被忽略的** —— 模块里的注释写着"兼容旧顶层，**实际本版内部不用它**"（而且 39370534 正好是 la/A4 那一档的值，说明是从旧版本抄来的）

> 🎯 **对你们方案的价值很大**：这个"**音符表 + 相位累加器 + 定长保持**"的结构，**正好能改造成 CPR 的节拍音（metronome）**！
> - 你们的方案要求"**同一计数器驱动节拍音与屏幕脉动**"（音画同步）
> - 现在有的零件是：① 能发任意频率正弦的 DDS ② "保持 N 帧就换下一个音"的计时结构
> - 你们要做的改造：把"每 0.5 秒换一个音"改成"**按目标按压频率（如 110 次/分 → 每 545 ms）响一声短促的 beep**"，并把那个计数器**同时**驱动屏幕脉动
> **这是你们 W5 音画同步的现成起点。**

#### 发现 3：ACR 的 N 是固定值，CTS 是**量出来的**（所以自动匹配真实时钟）

```verilog
parameter ACR_N = 6144
localparam AUDIO_DIV = ACR_N >> 7;          // = 6144 / 128 = 48
assign S_audio_valid_div = I_audio_valid && (S_audio_div_cnt == AUDIO_DIV-1);
...
O_acr_cts <= S_acr_cts_cnt + 1;             // ← 数出来的
O_acr_n   <= ACR_N;                         // ← 固定的
```

**HDMI 的 ACR 公式**（标准原文，见参考 [4]）：

```
128 × f_s = f_TMS_CLK × N / CTS
```

**自己推一遍**（这就是"算给读者看"）：

| 量 | 值 | 怎么来的 |
|---|---|---|
| 一个 ACR 测量窗口包含多少音频采样？ | `AUDIO_DIV = ACR_N ÷ 128 = 48` | 代码里就这么写的 |
| 48 个采样对应多长时间？ | `48 ÷ 48000 = **1 ms**` | 48 kHz 采样率 |
| 1 ms 里有多少个像素时钟？ | `25 MHz × 1 ms = **25000**` | 数出来就是 CTS |
| 代回公式验算： | `f_s = 25e6 × 6144 ÷ (128 × 25000) = **48000 Hz**` ✅ | 正好是 48 kHz |

**关键认识**：`N` 是标准表里的固定值（6144 对应 48 kHz），而 `CTS` 是**数真实像素时钟数出来的** —— 所以**无论 `video_clk` 是 25.000 还是 25.175 MHz，N/CTS 这一对都自动匹配**。

> ⭐ **这本身是个值得学的设计习惯**：**能测的量就不要硬编码**。硬编码 CTS 的话，换成 25.175 MHz 的板子就会出错；测出来则天然兼容。

### 术语卡（音频）

| 术语 | 意思 |
|---|---|
| **I2S** | 数字音频串行协议，3 根线：`BCLK`（位时钟）、`LRCK`（左右声道选择）、`DOUT`（数据） |
| **MCLK** | 音频主时钟（Master Clock），通常是采样率的 256 倍：`48000 × 256 = 12.288 MHz` ✅ |
| **LRCK** | 也叫 WS（Word Select）。低 = 左声道，高 = 右声道（或相反，看约定） |
| **ACR** | Audio Clock Regeneration。HDMI 上音频时钟不单独传线，而是靠发"N/CTS"让接收端**重建**音频时钟 |
| **N / CTS** | 一对整数，满足 `128 f_s = f_TMDS × N / CTS`。接收端用它们算出音频采样率 |
| **DDS** | 直接数字频率合成：用相位累加器 + 查表产生任意频率的正弦 |

---

## 六、那几条"胶水逻辑"（顶层唯一该写的逻辑）

顶层的 `assign` / `always` 只有 **3 处**，每一处都"必须是顶层做"：

| # | 代码 | 位置 | 为什么必须是顶层 |
|---|---|---|---|
| 1 | `assign rst_all = ~rst_n \| ~audio_pll_lock;` | 114 | 复位是**全局资源**，只有一个地方能定义它 |
| 2 | `always ... frame_write_toggle_mem <= ~frame_write_toggle_mem;` | 143~148 | 这是**两个模块之间的跨域适配**，属于"接线"的一部分，但不属于任何一方 |
| 3 | `assign vout_data = display_valid ? vout_data_raw : 24'd0;` | 224 | 见下 —— 它是**跨两个模块的语义决策** |

### 第 3 条展开：`display_valid` 门控（"首图黑屏"）

```verilog
// 首图提交前黑屏；提交后一直显示当前显示缓冲区内容
assign vout_data = display_valid ? vout_data_raw : 24'd0;
```

| 项 | 说明 |
|---|---|
| `display_valid` 从哪来 | `sd_card_bmp` 的**输出**（第 164 行） |
| 它在模块内部怎么产生 | 复位时 0；**只有第一次成功提交图片时**才置 1（`disp_buf_idx <= pending_buf_idx; display_valid <= 1'b1; first_image_committed <= 1'b1;`） |
| 置 1 之后会清 0 吗 | **不会** —— 它是"**曾经至少有一张图提交过**"的记忆 |
| 为什么需要它 | **上电时 SDRAM 内容是垃圾值**。没有这个门控，屏幕上会先出现雪花/撕裂的鬼影，直到第一张图写完 |
| 为什么放在顶层而不是内部 | 因为门控的是 `video_delay` 的输出（显示通路），而 `display_valid` 来自 SD 通路 —— **只有顶层同时看得见这两边** |

> 💡 这是一个很好的"**顶层该做什么**"的例子：**当一段逻辑的输入来自 A 模块、输出要给 B 模块，而且它表达的是"业务决策"（首图黑屏）时，放在顶层是合理的**。如果把它塞进 `video_delay`，那个模块就被污染了（它本该只管延迟对齐）。

---

## 七、★ 预习卡五个问题的答案

### Q1：`write_buf_idx` / `disp_buf_idx` 分别在哪里被改？时机对不对？

**两个都是 `sd_card_bmp` 的输出**（`output reg [1:0]`，在 `sd_card_clk` = 100 MHz 域），**顶层只是把它们转发给 `frame_read_write`**：

```verilog
.read_addr_index (disp_buf_idx),    // 读侧用"显示"指针
.write_addr_index(write_buf_idx),   // 写侧用"写入"指针
```

**改动的时机（在 `sd_card_bmp` 内部）**：

| 指针 | 什么时候改 | 改成什么 |
|---|---|---|
| **`write_buf_idx`** | **一发起"加载下一张"就改** | `next_buf_lut(disp_buf_idx, display_valid)` = **当前显示的那块的"另一块"** |
| **`disp_buf_idx`** | ⚠️ **只在"源发完 + 整帧真写完"之后才改** | `pending_buf_idx` |

关键代码（`sd_card_bmp.v`）：

```verilog
// 记住 bmp_read 已经把源图送完 FIFO，但还不能切显示，得等整帧写完
if (load_busy && bmp_ready)  source_done_seen <= 1'b1;

// 只有真正收到 write_finish_toggle 脉冲，才提交新图并切换显示缓冲区
if (load_busy && source_done_seen && write_finish_pulse) begin
    disp_buf_idx <= pending_buf_idx;      // ★ 此刻才切显示
    display_valid <= 1'b1;
end
```

| 判断 | 结论 |
|---|---|
| 会不会**读到正在写的那一块**？ | ❌ 不会。写入立刻切到"另一块"，显示块在此期间保持不变 |
| 会不会**显示半张图**？ | ❌ 不会。提交条件是**两个**（源发完 **且** 整帧写完），少了任一个都会撕裂 |
| 时机**对不对**？ | ✅ **对，而且很讲究**。这正是一个合格双缓冲该有的行为 |

> ⭐ **一个容易忽略的精妙点**：提交用的是 `write_finish_pulse`（从 125 MHz 域同步来的），而不是"源发完了"。因为**`bmp_read` 把数据推进 FIFO ≠ 数据已经落进 SDRAM** —— FIFO 里可能还有几十个字没搬完。**等"整帧真写完"才切，才是安全的。**

### Q2：`display_valid` 怎么产生的？为什么要有它？

见第六节第 3 条。**一句话**：它是"**已经至少成功显示过一张图**"的标志，顶层用它把"上电到首图"这段时间的输出**强制为黑色**，避免 SDRAM 垃圾数据造成的雪花/鬼影。

### Q3：三个 PLL 分别产生哪些时钟？哪些接了、哪些是历史遗留？

见第三节的完整时钟表。**一句话总结**：

- `sys_pll` → **3 路全用了**：100 MHz（SD）、125 MHz（存储）、125 MHz 移相（只喂 SDRAM 时钟脚）
- `video_pll` → **2 路全用了**：25 MHz（显示）、125 MHz（TMDS 串行）
- `PLL_HDMI_AUDIO` → **只用 1 路**：12.288 MHz（音频）；**75 MHz 和 375 MHz@90° 都悬空**，是从"I2S→HDMI"那个工程复用过来的历史遗留

**怎么自己发现历史遗留？** ✅ **看 STA 报告的 `Fanout` 列** —— `clk7: 75.002 fanout 0` 就是证据。

### Q4：音频从哪来？

**内部产生的**，而且**是一段 8 音音阶**（do~do，每音 0.5 秒），不是 SD 卡上的文件。详见 5.7 节的"发现 1/2"。

### Q5：如果要加"按键切换图片"，应该改顶层的哪几行？

**⚠️ 预习卡猜错了 —— 不需要改任何一行，因为已经实现了。**

| 已有 | 位置 | 功能 |
|---|---|---|
| `key1`（B2） | 顶层 L5、L159 → `sd_card_bmp.key_next` | **手动切下一张** |
| `key2`（C1） | 顶层 L6、L160 → `sd_card_bmp.key_auto` | **自动轮播 开/关** |

**真正需要"加按键"的情形**（如果你们要更多功能）：

| 步骤 | 改哪 | 说明 |
|---|---|---|
| 1 | 顶层端口表加 `input key3,` | 顶层是对外接口的唯一出口 |
| 2 | `pin.adc` 加 `set_pin_assignment { key3 } {...}` | 分配管脚（**别忘了这步，否则综合报"未约束 IO"**） |
| 3 | 把 `key3` 接到你们自己的调度器 | ⚠️ **不是接 `sd_card_bmp`** —— 那个模块你们要重写（第5站第十节） |
| 4 | 用哪个键？ | 板载 4 键是 **A2/B2/B1/C1**；现在 A2=`rst_n`、B2=`key1`、C1=`key2`，**只剩 B1 可用** |

> ⭐ **这一问的教训**：**"要改哪几行"这类问题，必须先看顶层端口 + `pin.adc`，再回答**。预习卡凭"通常按键没接"的直觉猜，就猜错了。**先看证据，再下结论** —— 这也是我这一路反复强调的（我已经在 74 时钟、突发跨行两处栽过跟头）。

---

## 八、几个额外的细节

### 8.1 `video_clk` 是 25.000 MHz，而标准是 25.175 MHz

| 项 | 值 |
|---|---|
| 本工程 `video_clk` | **25.000 MHz**（video_pll 配置：50 MHz ÷ 2 倍频关系得到，非整数分频近似） |
| CEA-861 VIC 1（640×480p60）标准像素时钟 | **25.175 MHz** |
| 偏差 | ≈ **0.7%** |
| 后果①（显示） | 实际刷新率 ≈ `60 × 25/25.175 ≈ **59.6 Hz**`（而不是 59.94）。**绝大多数显示器能容忍**（它们靠 HSync/VSync 同步，不靠绝对时钟） |
| 后果②（音频） | ✅ **不受影响** —— 因为 ACR 的 CTS 是**测真实时钟**得到的（5.7 发现 3） |

**结论**：这是个"能跑，但不是严格合规"的地方。**不必改**，但要知道：如果遇到某台显示器挑刺，这里是一个可查的点。

### 8.2 数码管：6 位里只用 1 位

```verilog
seg_scan seg_scan_m0(
    .clk(clk), .rst_n(rst_n),         // ⚠️ 用的是原始 50 MHz，不是任何 PLL 输出
    .seg_data_0({1'b1,7'b1111_111}),  // 全灭
    ... 1~4 同样全灭 ...
    .seg_data_5({1'b1,seg_data_0})    // 只有第 5 位显示状态码
);
```

| 点 | 说明 |
|---|---|
| `seg_decoder` | **纯组合**（无时钟）：`state_code[3:0]` → 7 段码 |
| `seg_scan` | 用 `clk`（50 MHz）做多位数码管扫描；**只有第 5 位有内容**，其余 5 位写死"全灭" |
| `{1'b1, ...}` 的高位 | 是**小数点**段（灭） |
| **为什么用 50 MHz 而不是 PLL 时钟？** | 数码管扫描对频率精度没要求，用人手边最稳的时钟最省事（也少一个时钟域） |

> **对你们有参考**：你们要用数码管显示"按压速率"，直接把 `seg_data_0..5` 填上 6 位十进制就行，扫描逻辑现成。

### 8.3 `rst_n` 占了一个按键，但顶层注释没写

顶层注释把 `key1`/`key2` 写清楚了，但 `rst_n` 只写了名字 —— **实际上 A2 是板载 4 个按键之一**。光看顶层代码，你会以为 `rst_n` 是"某个复位电路"。

**教训**：**顶层的端口注释要写清"物理上是什么"**（"板载 KEY_A，按下即复位"），而不是只写逻辑含义。

---

## 九、坏味道（6 个）

### 9.1 `parameter BUSRT_BITS = 10;` —— 拼写错误 + 从未使用

```verilog
parameter BUSRT_BITS    = 10;      // ← 应为 BURST_BITS
```

| 问题 | 说明 |
|---|---|
| 拼写 | `BUSRT` 少了一个 `E`（对照第6站里是 `BURST_BITS`） |
| 更严重的是 | **它在整个文件里从未被引用** —— 是个死参数 |
| 后果 | 读者会花时间猜"它影响什么"，而答案是"什么都不影响"。**死参数比没参数更糟** |

### 9.2 三个 PLL 的 `reset` 全部接 `1'b0`

```verilog
sys_pll     ... .reset(1'b0)
video_pll   ... .reset(1'b0)
PLL_HDMI_AUDIO ... .reset(1'b0)
```

**PLL 永远不复位**。上电时靠 PLL 自己上电复位；但如果运行中需要"重新锁相"（比如时钟抖动异常后），**没有办法**。典型的"能跑就行"写法。

### 9.3 只有音频 PLL 的 lock 参与复位（见第四节）

`sys_pll` / `video_pll` 的 `extlock` **根本没引出来** → 这两路时钟即使没锁上，`rst_all` 也不会拉高，整个设计带着坏时钟继续跑。

**为什么这是隐患**：SD 域/存储域跑在未锁定的时钟上 → 时序全乱 → 数据损坏，但你**看不到任何错误指示**。

### 9.4 音频 PLL 白耗两路输出

75 MHz 和 375 MHz@90° 都悬空。虽然综合器会把没人用的输出优化掉（STA 里 fanout 0），但：
- **PLL 的功耗和资源占用是按整体配置来的**（这颗 PLL 仍然要跑 750 MHz 的 VCO）
- 换一个 `.ipc` 配置（只留 12.288 MHz）就能省下来
- 更重要的是：**读者会被这两路误导**（以为音频通路需要 375 MHz 的高速时钟）

### 9.5 `PHASE_INC` 是死参数，而且顶层还在传

```verilog
// 模块内部注释：parameter [31:0] PHASE_INC = 32'd39370534,  // 兼容旧顶层，实际本版内部不用它
// 顶层却仍然在传：
hdmi_audio_tone_i2s_64fs #( .PHASE_INC(32'd39370534), .AMP(24'sd2000000) ) ...
```

**顶层传了一个被忽略的参数** —— 而且那个值（39370534）正好是音符表里 la/A4 的那一档，会让人误以为"这是设置音高的地方"。**实际音高由模块内部的音阶表决定。**

### 9.6 `O_video_locked` 被丢掉

```verilog
.O_video_locked(),      // 悬空
```

HDMI 核提供了"视频已锁定"的指示，**顶层把它扔了**。对比音频 PLL 的 lock 被用起来 —— **保护力度不一致**。至少应该把它引到一个 LED 或数码管上，方便调试。

---

## 十、能学到什么

| # | 学到的东西 | 能迁移到哪 |
|---|---|---|
| 1 | **顶层只做四件事**：参数 / 时钟 / 复位 / 接线。**逻辑越少越好** | 你们自己写顶层时，先数一数 `assign`+`always` 有几条 |
| 2 | **顶层的正确读法**：端口 → 参数 → 时钟 → 复位 → 按数据流走 → 回头看胶水 | 任何别人的工程都能这样快速上手 |
| 3 | **时钟树要画出来**：谁产生、什么频率、给谁用、**有没有 fanout 0 的僵尸时钟** | 用 STA 报告的 `Fanout` 列自动发现 |
| 4 | **跨时钟域：快→慢的单拍事件必须转 toggle**（否则会整个丢脉冲） | 这是第2站/第5站同款手法的第三处，**已是本工程的固定套路** |
| 5 | **双缓冲的"提交条件"必须是两个**：源发完 **且** 整帧真写完 | 任何"生产/消费 + 双缓冲"的场景 |
| 6 | **能测的量不要硬编码**（ACR 的 CTS 是数出来的，所以换时钟天然兼容） | 所有"标准要求一个比例常数"的地方 |
| 7 | **顶层是唯一能做"跨模块合同核对"的地方** | 时序参数、缓冲区地址、数据切片，三张表都该在顶层对 |
| 8 | **PLL 的 lock 是免费的诊断信息，不用白不用** | 你们的顶层至少把用到的 PLL lock 都引出来 |
| 9 | **"用地址做变换"要在正确的层做**（第6站的翻转） | 接口形式决定功能放在哪一层 |

---

## 十一、你们的实现会不会用这个电路？

### 11.1 顶层的处理方式：**不搬，但要照它的结构自己写**

顶层的**代码**不能照搬（它连的是参考工程的模块），但**它的组织方式必须照搬**：

| 参考工程顶层的做法 | 你们的顶层要不要照做 |
|---|---|
| 参数集中定义（`FRAME_PIXELS`/`BUF0_ADDR`） | ✅ **照做**，而且要把 **HDMI 时序、缓冲区地址、分辨率** 都集中定义 |
| 三个 PLL 分区清晰（SD / 显示 / 音频） | ✅ 照做。你们的时钟域不会更少 |
| 按功能分区加注释（`// ==== TF 多图扫描 ====`） | ✅ 照做，这是 411 行能读下去的原因 |
| 顶层只做四件事 | ✅ 照做 —— **尤其别把按压判定逻辑写进顶层** |
| 只用音频 PLL 的 lock | ⚠️ **改进**：把用到的 PLL lock 都引出来参与复位 |

### 11.2 三个直接可复用的"零件"

| 零件 | 在哪 | 你们怎么用 |
|---|---|---|
| **音符表 + DDS + 定长保持** | `hdmi_audio_tone_i2s_64fs` | ⭐ **改造成 CPR 节拍音**（见 5.7 发现 2）—— 把"每 0.5 s 换音"改成"按目标频率发声"，并把计数器**同时**驱动屏幕脉动 → **音画同步** |
| **ACR 测量 CTS 的做法** | `audio_arc_calculate` | 照抄（能测就别硬编码） |
| **数码管 6 位扫描** | `seg_decoder` + `seg_scan` | 直接用，把 `seg_data_0..5` 换成你们的按压速率/次数 |

### 11.3 你们方案的三个模式，在顶层上怎么体现

| 你们的模块（方案 9.1） | 在顶层的落点 |
|---|---|
| `adc_ctrl` / `press_decode` / `peak_detect` / `rate_judge` | 新增一条"按压数据通路"，接片内 ADC（**与 SD/显示通路并行**） |
| `layer_mixer` / `scale_engine` / `scroll_text` / `font_render` | 插在 `video_delay` 输出和 `RGB→AXIS` 之间（**显示通路的最后一级**） |
| `i2s_tx` / `audio_visual` | 替换 `hdmi_audio_tone_i2s_64fs`（保留 I2S 接口和 ACR 那一段） |
| `interrupt_timer` / `rotate_timer` | 新增一个计时器模块，输出给 `layer_mixer` 和音频 |
| `brightness` / `key_debounce` | 接按键与显示通路 |

### 11.4 一条硬风险（来自前几站）

🔴 **时序**：参考工程在 `ext_mem_clk`（125 MHz）域有 **−6.301 ns** 的建立时间违例（见 `04_环境与工具/参考工程编译修复记录_TD6.2.1.md`）。
**你们要在显示通路上再加 `layer_mixer` 等模块 —— 但那些在 `video_clk`（25 MHz）域，余量巨大（WNS +29.678 ns）**，所以加在显示侧是**相对安全**的。
**危险的是往 125 MHz 的存储域加东西**（比如多一路 SDRAM 读通道做图层叠加）—— 那会直接撞上已有的违例。

---

## 十二、检查题

**答"结构与读法"类（本站重点）**：

1. 顶层只有哪四类句子？为什么说"411 行里真正需要动脑的只有约 35 行"？
2. 顶层的正确阅读顺序是什么？为什么不该从第 1 行顺着读？
3. 顶层只写了 3 处 `assign`/`always`。分别是什么？**为什么这三处"必须是顶层做"**？

**答"时钟与复位"类**：

4. 全工程有哪几个时钟域？各自频率和用途？哪个域是"只有 1 个负载"的、为什么？
5. `hdmi_5x_clk` 为什么必须是像素时钟的 **5 倍**？（从 TMDS 编码 + DDR 推一遍）
6. `rst_all` 由哪两项构成？为什么唯独音频 PLL 的 lock 参与了复位？这样做的隐患是什么？
7. 怎么用 STA 报告发现"生成了但没人用"的时钟？

**答"数据流与跨域"类**：

8. `frame_write_finish` 为什么不直接接到 `sd_card_bmp`，而要转成 `toggle`？请用周期数字说明"会丢脉冲"。
9. 画一遍从 SD 卡到 HDMI 差分对的完整数据通路（含每一次跨时钟域的位置）。
10. `read_data(video_read_data[31:8])` 这个切片，和写入侧的哪一行构成"合同"？为什么是 `[31:8]` 而不是 `[23:0]`？

**答"双缓冲与门控"类**：

11. `write_buf_idx` 和 `disp_buf_idx` 分别在什么时刻改变？为什么提交条件需要**两个**（源发完 + 整帧写完）？
12. `display_valid` 为什么放在顶层做门控，而不是塞进 `video_delay`？

**答"方案"类**：

13. （结合方案）你们要把音频从"音阶测试音"改成"CPR 节拍音"，**参考工程的哪个模块给了你们起点？要改哪几处？**
14. （结合方案）如果要在显示通路上加 `layer_mixer`，应该插在顶层的哪两个模块之间？为什么这里**比往 125 MHz 存储域加东西安全**？
15. （结合方案）你们至少要引出哪几个 PLL 的 lock 参与复位？为什么？

---

## 参考资料

| # | 资料 | 用在哪 |
|---|---|---|
| [1] | 本地：`06_例程精读/第0站~第6站` | 本站在汇总前面所有站 |
| [2] | [ADV8003 硬件手册（含 CEA-861 VIC 表：`0x01 = CEA 861 VIC 1 (480p_60 640)`）](https://ez.analog.com/cfs-file/__key/communityserver-wikis-components-files/00-00-00-01-10/8625.ADV8003_5F00_HW_5F00_Manual_5F00_RevB_5F00_150813.pdf) | 第二节 VIC 1；第五节 ACR 公式 |
| [3] | [Intel HDMI 设计指南：`Data rate < 1 Gbps → 5× TMDS clock frequency`](https://www.intel.com/content/dam/www/programmable/us/en/pdfs/literature/ug/ug-dex-hdmi-c10gx.pdf) | 3.2 节 hdmi_5x_clk |
| [4] | [ADV8003 手册中的 ACR 公式 `128 f_s = f_TMS_CLK × N / CTS`](https://ez.analog.com/cfs-file/__key/communityserver-wikis-components-files/00-00-00-01-10/8625.ADV8003_5F00_HW_5F00_Manual_5F00_RevB_5F00_150813.pdf) | 5.7 发现 3 |
| [5] | [TI：ACR Audio Frequency Register (FREQ_SVAL)](https://www.ti.com/lit/ug/sprugx7c/sprugx7c.pdf) | 5.7 发现 3（另一处 ACR 参考） |
| [6] | 本地：`_ref/规格书/BMP格式规范.md` | 5.4 节读数据切片的写入侧约定 |
| [7] | 本地：`04_环境与工具/参考工程编译修复记录_TD6.2.1.md` | 11.4 节时序风险 |

---

## 📎 本站（也是全部走读）明确没讲的东西

| 内容 | 为什么没讲 |
|---|---|
| **`sdram.v` / `sdr_as_ram` 内部** | ⚠️ **唯一还没走读的模块**。第6站留的两个"待确认"（跨行突发、读写仲裁）答案都在这里 |
| HDMI 核内部（`hdmi_1_4b_transmitter_core_wrapper.enc.v`） | **加密文件**（`.enc.v`），读不了 |
| TMDS 编码算法细节（8b/10b 的 DC 平衡） | 属于 HDMI 物理层，本工程直接用 IP |
| EDID 的具体内容解析 | 本工程只"读"，不解析（`edid_valid`/`edid_data` 都悬空没用） |
| I2S 时序的相位细节 | 属于音频协议，用到时再查 |

---

*上一站 → `第5站_SD卡SPI链路.md` ｜ 下一站 → （第6站 `第6站_SDRAM读写引擎_frame_fifo.md`）｜ 🎉 **8 站走读到此完成** —— 唯一剩下的是 `sdram.v`*
