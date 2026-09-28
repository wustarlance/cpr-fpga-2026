# 第3站：`video_delay.v` —— 读延迟补偿

> 文件：`05_lab_ex/lab_ex5_i2s/src/user_source/hdl_source/SD/video_delay.v`（52 行）
> 本站是全工程**最容易被忽略、但最不能少**的一块。

---

## 一、它在解决什么问题（先看问题，再看代码）

一句话：

> **你向 FIFO 要一个像素，数据不会立刻回来。等它回来的时候，行的同步信号已经跑到前面去了。这个模块就是让两边重新对上。**

具体数字：

| 环节 | 延迟 |
|---|---|
| 发出 `read_en` → FIFO 输出数据 | **1 拍**（同步 FIFO 的读延迟） |
| 数据再打一级寄存器（让信号干净） | **1 拍** |
| **合计落后** | **2 拍** |

所以：**同步信号（hs/vs/de）必须一起往后多延迟 2 拍，才能和"迟到"的数据对齐。**

如果不做这件事会怎样？——**整幅画面向右偏移 2 个像素，而且左边冒出一条黑边。**（每行都偏 2 个像素，行首的同步信息也会错位。）

---

## 二、逐行读

### 块1：端口（第 1~19 行）

```verilog
module video_delay
#(
	parameter DATA_WIDTH = 24          // 一个像素 24 位
)
(
	input                       video_clk,   // 像素时钟
	input                       rst,
	output                      read_en,     // 向 FIFO 发读请求
	input[DATA_WIDTH - 1:0]     read_data,   // 从 FIFO 读回的像素
	input                       hs, vs, de,  // 来自第1站
	output                      hs_r, vs_r, de_r,        // 对齐后的同步信号
	output[DATA_WIDTH - 1:0]    vout_data                // 对齐后的像素
);
```

**术语卡**

| 术语 | 意思 |
|---|---|
| `parameter` | **参数**：写在模块头上，例化时可以覆盖。比如另一处可以写 `video_delay #(.DATA_WIDTH(16))` |
| `DATA_WIDTH = 24` | 一个像素 24 位 = **RGB888**（红绿蓝各 8 位）。对照：RGB565 是 16 位 |
| `_r` 后缀 | 惯例表示 **registered**（打过拍/寄存过的） |
| `video_clk` | **像素时钟**。第1站的 `de = 1` 就代表"这一拍是一个有效像素" |

> ⚠️ **顺手记一个疑点**：这个模块 `DATA_WIDTH = 24`，但第1站 `video_timing_data.v` 写的是 `DATA_WIDTH = 16`。**两个数不一致**——第3站末尾的检查题会用到这一点。

---

### 块2：三根延迟线（第 20~23 行）

```verilog
reg [20:0] hs_d;
reg [20:0] vs_d;
reg [20:0] de_d;
reg[DATA_WIDTH - 1:0]  vout_data_r;
```

**这三根不是"数字"，是"延迟线"。**

`[20:0]` = 21 位。每一位都是同一个信号在**不同时刻**的快照：

```
      bit20  bit19  bit18 ......... bit1  bit0
        │      │      │              │     │
      21拍前  20拍前  19拍前        2拍前  1拍前
```

**术语卡**

| 术语 | 意思 |
|---|---|
| **抽头（tap）** | 延迟线中间某一级的输出。`hs_d[18]` 就是一个抽头 |
| **移位寄存器** | 每来一拍，数据整体往左推一格 |
| `de_d[k]` 的延迟拍数 | **k + 1 拍**（因为 `de_d[0]` 已经延迟了 1 拍）——**这里最容易数错** |

---

### 块3：五个连续赋值（第 25~29 行）

```verilog
assign read_en   = de_d[18];      // de 延迟 19 拍 → 发读请求
assign hs_r      = hs_d[20];      // de 延迟 21 拍 → 对齐后的 hs
assign vs_r      = vs_d[20];
assign de_r      = de_d[20];
assign vout_data = vout_data_r;
```

**术语卡**

| 术语 | 意思 |
|---|---|
| `assign`（连续赋值） | **组合逻辑**：右边一变，左边立刻跟着变，不需要时钟 |
| `<=`（非阻塞赋值） | **时序逻辑**：写在 `always @(posedge clk)` 里，时钟沿才生效 |

**关键**：`read_en` 用 **第 19 拍**，`de_r/hs_r/vs_r` 用 **第 21 拍**。
→ `read_en` **比 `de_r` 早 2 拍**。

这 2 拍，正好就是前面那张表里的「FIFO 读延迟 1 拍 + 输出寄存器 1 拍」。

---

### 块4：移位逻辑（第 39~51 行）

```verilog
always @(posedge video_clk or posedge rst) begin
	if(rst) begin
		hs_d <= 20'b0;
		vs_d <= 20'b0;
		de_d <= 20'b0;
	end
	else begin
		hs_d <= {hs_d[19:0],hs};
		vs_d <= {vs_d[19:0],vs};
		de_d <= {de_d[19:0],de};
	end
end
```

**核心就一行**：

```verilog
hs_d <= {hs_d[19:0], hs};
```

拆开看：

| 片段 | 含义 |
|---|---|
| `{ ... , ... }` | **拼接（concatenation）**：把两个信号首尾接成一个更宽的 |
| `hs_d[19:0]` | 原来的低 20 位 |
| 整体意思 | 低 20 位左移一格，**最低位塞进当前的 `hs`**，最高的 `hs_d[20]` 被挤掉 |

结果：`hs_d[0]` 永远等于"上一拍的 hs"，`hs_d[20]` 等于"21 拍前的 hs"。

---

### 块5：数据寄存（第 30~38 行）

```verilog
always@(posedge video_clk or posedge rst)
begin
	if(rst == 1'b1)
		vout_data_r <= {DATA_WIDTH{1'b0}};
	else if(de_d[19])                 // 第 20 拍
		vout_data_r <= read_data;      // 把读回的像素存下来
	else
		vout_data_r <= {DATA_WIDTH{1'b0}};   // 消隐期输出全 0（黑）
end
```

**术语卡**

| 术语 | 意思 |
|---|---|
| `{DATA_WIDTH{1'b0}}` | **位宽复制**：把 1 位 0 复制 24 次 → 24 位全 0。等价于 `24'h0` |
| 为什么 `else` 要写 0 | **消隐期（blanking）必须送黑**，否则屏幕上会出现雪花或残影 |

---

## 三、算一笔账（本站最重要的一张图）

```
拍数:      0            19        20         21
           │             │         │          │
de ────────┘             │         │          │
                         ▼         │          │
                    read_en        │          │
                         │         │          │
                    ┌────┴────┐    │          │
                    │  FIFO   │ 1拍│          │
                    └────┬────┘    │          │
                         │         │          │
                    read_data ─────┤          │
                                   ▼          │
                              vout_data_r  ───┤ 1拍寄存器
                                              ▼
                                          vout_data
                                              
de ──── 延迟 21 拍 ─────────────────────────→ de_r
```

**验算**：设第 `p` 拍的 `de` 对应第 `p` 个有效像素

| 时刻 | 发生了什么 |
|---|---|
| 第 p 拍 | `de = 1`（第 p 个有效像素） |
| 第 p+19 拍 | `read_en = de_d[18] = 1` → 向 FIFO 发读请求 |
| 第 p+20 拍 | FIFO 输出数据；`de_d[19] = 1` → 存入 `vout_data_r` |
| 第 p+21 拍 | `vout_data` 有效；`de_r = de_d[20] = 1` ✅ **完全对齐** |

### 可以直接抄走的两条结论

1. **同步信号与数据必须延迟同样的拍数**（这里 hs/vs/de/vout_data 都是 21 拍）
2. **`read_en` 必须比 `de_r` 早「FIFO 读延迟 + 输出寄存器级数」拍**（这里是 1+1=2 拍）

---

## 四、顺带的一个好处：省 27% 读带宽

`read_en = de_d[18]` —— 它只在**有效像素期**为 1。

- 一帧**有效像素**：640 × 480 = **307,200** 个
- 一帧**总拍数**：800 × 525 = **420,000** 拍
- 消隐期完全**不读 FIFO** → 省掉约 **27%** 的读带宽

> ⚠️ **前提**：写端也只在有效像素期写入。两边约定必须一致，否则整幅画面会错位。
> 这条要等第6站看 `frame_fifo_write.v` 时才能确认——**先记下来。**

---

## 五、能学到什么

1. **读延迟补偿是通用技巧，不是这个例程特有的。**
   以后你们写 SPI 读 SD 卡、从 SDRAM 取数、跨时钟域收数据——只要"发出请求"和"拿到数据"之间隔了几拍，就要做这件事。
2. **移位寄存器做延迟线**是 Verilog 里最常用的写法。`{x[N-2:0], x}` 这个模式要记牢，往后会反复见到。
3. **流水线对齐的思维**：任何时候有多路信号一起走，都要问一句——
   **"它们各自经过了几级寄存器？"** 差一级就错位。

---

## 六、你们的实现会不会用这个电路？

### 结论：**会，而且绕不开。**

你们的图像要从 SD 卡 → SDRAM → HDMI，只要中间隔了一个存储器，就必然有读延迟，就必然要做对齐。

### 但**不要照抄**，建议这样改写

| 参考工程 | 建议你们 | 为什么 |
|---|---|---|
| 硬编码 `18 / 19 / 20 / 21` | `parameter FIFO_LATENCY = 1;`<br>`localparam TOTAL = FIFO_LATENCY + 2;` | 换 FIFO 配置或改流水线时只改一处；硬编码要满文件找魔数 |
| 三根独立的 21 位移位寄存器（63 个触发器） | 打包成**一根 3 位宽 × 21 深**的延迟线 | 少写两段 `always`，不容易漏信号 |
| 只延迟 hs / vs / de | 把 **所有伴随信号**（`data_valid`、`frame_start`、行号…）一起延迟 | 漏一个就错位 |
| 无注释 | 写清楚「`read_en` 比 `de_r` 早 2 拍 = FIFO 1 拍 + 寄存器 1 拍」 | 三个月后你自己也看不懂 |

### 直接抄走：一个通用延迟线模块

```verilog
// 把 WIDTH 位信号延迟 DEPTH 拍
module delay_line #(
    parameter WIDTH = 1,
    parameter DEPTH = 1
)(
    input  wire             clk,
    input  wire             rst,
    input  wire [WIDTH-1:0] din,
    output wire [WIDTH-1:0] dout
);
    reg [WIDTH-1:0] sr [0:DEPTH-1];
    integer i;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (i = 0; i < DEPTH; i = i + 1) sr[i] <= {WIDTH{1'b0}};
        end else begin
            sr[0] <= din;
            for (i = 1; i < DEPTH; i = i + 1) sr[i] <= sr[i-1];
        end
    end
    assign dout = sr[DEPTH-1];
endmodule
```

用法：`delay_line #(.WIDTH(3), .DEPTH(21)) u_dly (.clk(video_clk), .rst(rst), .din({hs,vs,de}), .dout({hs_r,vs_r,de_r}));`

一行搞定 hs/vs/de 三路对齐。

---

## 七、一个"坏味道"（要能识别出来）

**魔数（magic number）**：`18`、`19`、`20`、`21` 四个数字在代码里没有任何说明。

这是这类代码的典型问题——**能跑，但改不动**。

**判断标准**：如果换一个读延迟不同的 FIFO，你需不需要改这个文件？
**需要 → 它就该参数化。**

---

## 八、检查题（答完我们进第4站 `bmp_read.v`）

1. 如果 FIFO 的读延迟从 **1 拍变成 2 拍**，`read_en`、`de_d[19]`、`de_d[20]` 这三个抽头分别应该改成多少？
2. 为什么 `hs_r/vs_r/de_r` 用 `[20]`，而 `read_en` 用 `[18]`？它们差的那 **2 拍**是在等谁？
3. 数据寄存那里如果改成 `else if(de_d[20])`（而不是 `de_d[19]`），画面会怎样？
4. 第1站的 `video_timing_data` 写 `DATA_WIDTH = 16`，这里写 `24`。从数据流看这两个模块**并不串联**——请说出它们各自在链路里的位置，并判断这个不一致要不要紧。
5. （承上）消隐期不读 FIFO 能省 27% 带宽，但前提是**写端也只写有效像素**。你能在第2站的 `frame_read_write.v` 或 `frame_fifo_write.v` 里找到写端是怎么控制的吗？
