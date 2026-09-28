# 第2站：`frame_read_write.v` —— 帧缓存读写（时钟域的"换乘站"）

> 文件：`SD/frame_read_write.v`（193 行）
> ⚠️ **这一站你还没看过，所以写得比其他站细。**

---

## 一、它在解决什么问题

先说结论：**它是整个工程里三个时钟域的交汇点。**

| 时钟 | 频率 | 谁在用 |
|---|---|---|
| `write_clk` | **100 MHz**（`sd_card_clk`） | SD 卡 / BMP 解析，往帧缓存**写**像素 |
| `mem_clk` | **125 MHz**（`ext_mem_clk`） | 片内 SDRAM，读写仓库 |
| `read_clk` | **25 MHz**（`video_clk`） | HDMI 显示，从帧缓存**读**像素 |

三个时钟频率不同、相位无关。**像素要从 100MHz 的世界搬到 25MHz 的世界，中间还得经过 125MHz 的 SDRAM。**

> **这个模块就是"换乘站"：进站、出站、换时钟。**

关键点：**跨时钟域不能直接连线**（会有亚稳态、会丢数据），必须用**异步 FIFO** 过渡。这个模块里有**两个**异步 FIFO，一个负责"进"，一个负责"出"。

---

## 二、先看端口（学会给端口分组）

端口一共有三类，看名字前缀就能分清：

### ① SDRAM 侧（都在 `mem_clk` 域）

```verilog
input  Sdr_init_done;        // SDRAM 初始化完成
input  Sdr_init_ref_vld;
input  Sdr_busy;             // SDRAM 正忙
output App_wr_en;            // 应用层：写请求
output [ADDR_BITS-1:0] App_wr_addr;   // 应用层：写地址
output [MEM_DATA_BITS-1:0] App_wr_din; // 应用层：写数据
output [3:0] App_wr_dm;      // 写掩码（Data Mask）
output App_rd_en;            // 应用层：读请求
output [ADDR_BITS-1:0] App_rd_addr;
input  Sdr_rd_en;            // SDRAM 读数据有效
input  [MEM_DATA_BITS-1:0] Sdr_rd_dout;  // SDRAM 读出的数据
```

**术语卡**

| 术语 | 意思 |
|---|---|
| `App_` 前缀 | "应用层接口"——SDRAM 控制器暴露给你用的简化接口 |
| `Sdr_` 前缀 | "SDRAM 控制器→你"方向的信号 |
| **`dm`（Data Mask）** | **写掩码**：4 位对应 32 位的 4 个字节，某位为 1 表示**这个字节不写**。这里恒为 `4'b0000` = 4 字节全写 |

### ② 写侧（都在 `write_clk` 域，来自 SD 卡模块）

```verilog
input  write_clk;            // = sd_card_clk (100MHz)
input  write_req;            // 请求写一帧
output write_req_ack;
output write_finish;
input  [ADDR_BITS-1:0] write_addr_0;   // 缓冲区 0 的基地址
input  [ADDR_BITS-1:0] write_addr_1;   // 缓冲区 1
input  [ADDR_BITS-1:0] write_addr_2;   // 缓冲区 2 ← 顶层没用
input  [ADDR_BITS-1:0] write_addr_3;   // 缓冲区 3 ← 顶层没用
input  [1:0] write_addr_index;         // 2 位索引，选 0~3 号缓冲区
input  [ADDR_BITS-1:0] write_len;      // 一帧多少像素
input  write_en;                       // 每个像素的写使能
input  [WRITE_DATA_BITS-1:0] write_data;  // 像素数据
```

### ③ 读侧（都在 `read_clk` 域，送给显示）

```verilog
input  read_clk;             // = video_clk (25MHz)
input  read_req;
output read_req_ack;
output read_finish;
input  [ADDR_BITS-1:0] read_addr_0 ~ read_addr_3;
input  [1:0] read_addr_index;
input  [ADDR_BITS-1:0] read_len;
input  read_en;              // 来自第3站的 video_delay
output [READ_DATA_BITS-1:0] read_data;
```

> **注意 `read_en` 的注释**：
> ```verilog
> input read_en,   // data read module read request for one data, read_data valid next clock
> ```
> **"read_data valid next clock"——读延迟 1 拍。** 这就是第3站 `video_delay` 里"那个 2 拍"的来源。**两站在这里对上了。**

---

## 三、参数（第 3~14 行）

```verilog
parameter MEM_DATA_BITS   = 32;    // SDRAM 数据宽度 32 位
parameter READ_DATA_BITS  = 32;    // 读数据宽度
parameter WRITE_DATA_BITS = 32;    // 写数据宽度
parameter ADDR_BITS       = 21;    // 2^21 = 2,097,152 个地址单元
parameter BURST_BITS      = 9;     // 突发长度最大 512
parameter BURST_SIZE      = 256;   // 每次突发 256 个字
parameter WRITE_V_FLIP    = 1;     // 写入时垂直翻转
parameter FRAME_WIDTH     = 640;
parameter FRAME_HEIGHT    = 480;
```

### 两个值得停下来想的点

**① `ADDR_BITS = 21`，但 SDRAM 是 2M×32bit**

2²¹ = 2,097,152 ≈ 2M。所以 **地址的单位是"32 位字"，不是字节**。

**验证**：顶层传的 `BUF1_ADDR = 307200`，而 640×480 = **307200**。
→ **一个缓冲区地址 = 一帧像素数** → 证实地址单位就是"像素/字"。✅

**② `WRITE_V_FLIP = 1`：写入时垂直翻转**

BMP 文件的行序和显示器扫描的行序是**相反**的。在**写入**时翻转一次，读的时候就不用管了。
→ **设计哲学：把麻烦解决在源头，让读侧（实时性要求高的一侧）保持简单。**

---

## 四、核心：四个实例（这就是全模块的骨架）

### 实例 1：`wfifo_32_32_512 write_buf` —— 进站的换乘大厅

```verilog
wfifo_32_32_512 write_buf (
    .clkr   (mem_clk),        // 读侧时钟 = SDRAM 时钟
    .clkw   (write_clk),      // 写侧时钟 = SD 卡时钟
    .rst    (write_fifo_aclr),
    .we     (write_en),       // 写请求 ← 来自 SD 卡模块
    .re     (App_wr_en),      // 读请求 ← 来自 frame_fifo_write
    .di     (write_data),     // 写入：像素
    .dout   (App_wr_din),     // 读出：送给 SDRAM
    ...
);
```

**数据方向**：`write_clk` 域写入 → `mem_clk` 域读出 → 送 SDRAM
**名字含义**：`wfifo_32_32_512` = 位宽32 / 深32? / 深512

### 实例 2：`frame_fifo_write` —— 写引擎

把 FIFO 里的数据组织成**突发（burst）**，按 `write_addr_index` 选中的基地址写进 SDRAM。
输出 `App_wr_en` / `App_wr_addr`。

### 实例 3：`rfifo_32_32_512 read_buf` —— 出站的换乘大厅

```verilog
rfifo_32_32_512 read_buf (
    .clkr   (read_clk),       // 读侧时钟 = 视频时钟
    .clkw   (mem_clk),        // 写侧时钟 = SDRAM 时钟
    .rst    (read_fifo_aclr),
    .we     (Sdr_rd_en),      // 写请求 ← SDRAM 读数据有效
    .re     (read_en),        // 读请求 ← 来自 video_delay
    .di     (Sdr_rd_dout),    // 写入：SDRAM 读出的数据
    .dout   (read_data),      // 读出：送给 video_delay
    ...
);
```

**数据方向**：`mem_clk` 域写入（SDRAM 数据）→ `read_clk` 域读出（视频用）

### 实例 4：`frame_fifo_read` —— 读引擎

按 `read_addr_index` 选中的基地址，从 SDRAM 突发读出，产生 `Sdr_rd_en`。

---

## 五、数据流全景图

```
  SD卡 / BMP解析                 SDRAM 控制器                  HDMI 显示
  (100MHz)                       (125MHz)                     (25MHz)
      │                              │                             │
      │ write_en/write_data          │                             │
      ▼                              │                             │
 ┌─────────┐   App_wr_din     ┌──────────────┐                    │
 │ wfifo   │─────────────────▶│ frame_fifo_  │  App_wr_en/addr    │
 │write_buf│                  │   write      │───────────────────▶│
 └─────────┘                  └──────────────┘                    │
      ▲                              ▲                             │
      │ clkw=write_clk               │ 都在 mem_clk 域             │
      │ clkr=mem_clk                 │                             │
      │                              │                    ┌────────┴────────┐
      │                              │                    │    SDRAM        │
      │                              │                    │  (2M × 32bit)   │
      │                              │                    └────────┬────────┘
      │                              │                             │
 ┌─────────┐   read_data      ┌──────────────┐  Sdr_rd_en/dout    │
 │ rfifo   │◀─────────────────│ frame_fifo_  │◀───────────────────┘
 │read_buf │                  │   read       │
 └─────────┘                  └──────────────┘
      │                              ▲
      │ read_en                      │ 都在 mem_clk 域
      ▼                              │
 video_delay (第3站)                 │
      │ clkw=mem_clk
      │ clkr=read_clk
```

---

## 六、⭐ 上次留的三道题，答案在这里

### Q1：哪个 FIFO 的 `clkw` 接的是 `mem_clk`？

**答：`rfifo_32_32_512 read_buf`（读侧那个）。**

| FIFO | `clkw`（写侧） | `clkr`（读侧） | 数据从哪来 → 到哪去 |
|---|---|---|---|
| `wfifo` write_buf | `write_clk` | `mem_clk` | 从 **SD卡(100M)** 来 → 到 **SDRAM(125M)** 去 |
| `rfifo` read_buf | **`mem_clk`** | `read_clk` | 从 **SDRAM(125M)** 来 → 到 **视频(25M)** 去 |

**规律（可以直接背下来）**：

> **FIFO 的 `clkw` 跟着"数据从哪来"，`clkr` 跟着"数据到哪去"。**

**为什么不能接错**：FIFO 的写侧必须用**产生数据那一方的时钟**，否则写请求和数据的先后关系就不确定了。

### Q2：这个模块里有几个 `always` 块？

**答：0 个。**

验证方法：
```bash
grep -c "always" frame_read_write.v   # → 0
```

**说明什么**：它是一个**纯结构化模块（structural module）**——
- 只做「例化」和「连线」（`assign`）
- **所有逻辑都在子模块和 IP 里**
- 它自己不"计算"任何东西

**这体现了一种好的分层习惯**：顶层和各层之间只管"谁接谁"，具体算法藏在各自的模块里。**改一处不动全身。**

### Q3：改成三缓冲，需要改这个模块内部吗？

**答：不需要。**

**为什么**：它的读/写地址端口**本来就是 4 组**：

```verilog
input [ADDR_BITS-1:0] write_addr_0, write_addr_1, write_addr_2, write_addr_3;
input [1:0]           write_addr_index;    // 2 位 → 能选 0/1/2/3
input [ADDR_BITS-1:0] read_addr_0,  read_addr_1,  read_addr_2,  read_addr_3;
input [1:0]           read_addr_index;
```

**2 位索引 = 天然支持 4 个缓冲区。** 硬件已经预留好了（叫 **headroom**，设计余量）。

顶层现在只用了 0 和 1（`read_addr_2/3` 接 0），所以：

> **改三缓冲，只需要改"顶层产生 index 的那段逻辑"**——
> 从"1 位翻转（0↔1）"改成"2 位计数（0→1→2→0），并跳过正在写的那个"。

**这是一条重要的设计经验**：**接口留余量，将来改需求时不用动已经验证过的模块。**

---

## 七、两个额外的细节（值得看）

### 细节1：读写仲裁——写优先

```verilog
assign App_wr_busy = O_wr_busy;   // 下个时钟写指令拉高
assign App_rd_busy = O_rd_busy;   // 读指令还没有过去十个时钟；
                                  // 因为写指令优先，不需要在意下个时钟是否是读指令
```

`frame_fifo_write` 把 `O_wr_busy` 给 `frame_fifo_read` 看，`frame_fifo_read` 把 `O_rd_busy` 给 `frame_fifo_write` 看——**互相通报"我正忙"**，用于避免冲突。

**仲裁规则是「写优先」**。为什么？
- **写是实时的**：SD 卡的数据来了必须马上存，否则 FIFO 溢出、数据丢了就没了
- **读可以等**：显示缓冲区里已经有一整帧，晚几拍显示看不出来

> **设计哲学：谁的数据"丢了就找不回来"，谁优先。**

### 细节2：写掩码固定为 0

```verilog
assign App_wr_dm = 4'b0000;   // 4 个字节全写
```

`dm` 是**写掩码**，某位为 1 表示"这个字节不写"。恒为 0 = 每次都写满 32 位。
→ **简化设计**：不做字节级的部分写。

### 细节3（小瑕疵）：位宽不匹配

顶层里写的是：
```verilog
.read_addr_2 (24'd0),    // 24 位常量
```
但端口是 `[ADDR_BITS-1:0]` = **21 位**。Verilog 会**静默截断**，不报错。写法不一致，建议统一。

另外文件第 22~29、47~54 行有一大段**被注释掉的 burst 原始接口**——说明这个模块从"裸 burst 接口"重构成了现在的 `App_` 简化接口。**注释可以删掉了**，留着容易误导。

---

## 八、能学到什么

1. **跨时钟域必须用异步 FIFO**，不能直接连线。
2. **FIFO 的 clkw/clkr 接法规律**：`clkw` 跟数据源，`clkr` 跟数据去向。
3. **分层设计的价值**：这一层只管连线（0 个 always），逻辑都在下一层——改需求时不用动它。
4. **接口留余量（4 组地址）**：以后升级三缓冲/四缓冲不用改这个文件。
5. **仲裁要有优先级**，原则是"丢不起的那一方优先"。
6. **双缓冲的意义**：写缓冲区 0 的时候，显示在读缓冲区 1，互不干扰——**这就是"边写边显示"不闪屏的原因**。

---

## 九、你们的实现会不会用这个电路？

**会用到"结构"，但会简化。**

| 参考工程 | 建议你们 |
|---|---|
| 两个异步 FIFO + 两个读写引擎 | **保留同样结构**（这是标准做法） |
| 4 组地址 + 2 位索引 | **可以先用 2 组**，但建议**保留 2 位索引端口**，方便以后升级 |
| 突发长度 256 | 按你们 SDRAM IP 的建议值调（参考工程是 256 字 = 1KB） |
| 读写仲裁（写优先） | 保留这个原则 |
| 双缓冲（BUF0/BUF1） | **必须保留**，否则会看到"撕裂"（上半屏是旧图、下半屏是新图） |

**一个提醒**：这个模块里的两个异步 FIFO（`wfifo_32_32_512` / `rfifo_32_32_512`）是**软核 IP**，用 TD 重新生成时必须保证参数一致（位宽 32、深度 512、非 FWFT 模式）。**如果 IP 的读延迟不是 1 拍，第3站 `video_delay` 的 18/19/20/21 就要跟着改**——这就是那两个魔数的脆弱之处。

---

## 十、检查题（答完进第4站）

1. 如果 `wfifo` 的 `clkw` 也接成 `mem_clk`，会发生什么？
2. `ADDR_BITS = 21` 意味着地址单位是什么？用顶层的 `BUF1_ADDR = 307200` 验证一下。
3. 为什么 `WRITE_V_FLIP` 放在**写侧**做，而不是读侧？
4. 如果要加第三个缓冲区，**这个模块要改哪一行**？如果一行都不用改，那真正要改的是什么？
5. （承上，与第3站联动）`read_en` 的注释写着 "read_data valid next clock"。请说出第3站 `video_delay` 里 `read_en` 用 `de_d[18]` 而 `de_r` 用 `de_d[20]` 的**完整理由**。

---

*上一站 → `第1站_视频时序_video_timing_data.md` ｜ 下一站 → `第3站_读延迟补偿_video_delay.md`*
