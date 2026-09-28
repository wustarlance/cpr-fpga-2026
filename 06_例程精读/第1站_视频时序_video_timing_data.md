# 第1站：`video_timing_data.v` —— 产生 HS / VS / DE 时序

> 文件：`SD/video_timing_data.v`（84 行）
> ⚠️ **这个文件已经被改过**（修改时间 9月14 22:20，比同目录其他文件都新）

---

## 一、它在解决什么问题

HDMI 显示不是"把像素一股脑送出去"就行。显示器需要三根"伴走信号"：

| 信号 | 全称 | 作用 |
|---|---|---|
| **hs** | horizontal sync，行同步 | 告诉显示器"这一行结束了" |
| **vs** | vertical sync，场同步 | 告诉显示器"这一帧结束了" |
| **de** | data enable，数据有效 | 告诉显示器"这一拍上的 RGB 是真正的像素"（不是消隐期） |

**这个模块的职责**：产生这三根信号，并在合适的时刻发出"请读一帧数据"的请求。

### 一个"偷懒"但聪明的做法

它**没有自己写 800×525 的计数器**，而是**例化了一个现成的彩条发生器 `color_bar`，然后把它的 RGB 输出丢掉，只留下 hs/vs/de**：

```verilog
color_bar color_bar_m0(
    .clk(video_clk), .rst(rst),
    .hs(video_hs), .vs(video_vs), .de(video_de),
    .rgb_r(), .rgb_g(), .rgb_b()      // ← 空着不接 = 丢弃
);
```

**术语**：把输出端口"空着不接"（`.rgb_r()`）在 Verilog 里表示**这个输出我不用**。

**为什么这样做**：时序发生器（counter + 比较器）是重复劳动，`color_bar` 里已经写好了而且经过了验证。**复用它只留时序，比自己重写一遍更不容易错。**

---

## 二、逐行读

### 块1：参数与端口（第 1~16 行）

```verilog
parameter DATA_WIDTH = 16
```

> ⚠️ **这个 16 现在是个"死参数"**。因为相关的 `read_data` / `vout_data` 端口都被注释掉了，`DATA_WIDTH` 在当前版本里根本没用上。
> （原设计里它可能是 RGB565 = 16 位；而数据通路现在由第3站的 `video_delay` 负责，那边写的是 24 位 = RGB888。）

```verilog
output reg  read_req;        // 请求读一帧
input       read_req_ack;    // 对方应答
output      hs, vs, de;      // 时序
```

### 块2：两级延迟（第 17~52 行）

```verilog
reg video_hs_d0, video_vs_d0, video_de_d0;
reg video_hs_d1, video_vs_d1, video_de_d1;
...
video_hs_d0 <= video_hs;   // 第 1 拍
video_hs_d1 <= video_hs_d0; // 第 2 拍
...
assign hs = video_hs_d1;
assign vs = video_vs_d1;
assign de = video_de_d1;
```

**为什么要把 hs/vs/de 延迟 2 拍？**

`color_bar` 的输出是"组合逻辑刚算出来的"，直接送出去时序不好（布线延迟、毛刺）。**打两拍让信号变干净**，这是工程惯例（叫"寄存器化输出" / registered output）。

**术语**：**打拍**——插一级寄存器，代价是延迟 1 个时钟，收益是时序更容易收敛。

### 块3：帧读请求（第 64~72 行）

```verilog
always@(posedge video_clk or posedge rst)
begin
	if(rst == 1'b1)
		read_req <= 1'b0;
	else if(video_vs_d0 & ~video_vs)   // ← 边沿检测
		read_req <= 1'b1;
	else if(read_req_ack)
		read_req <= 1'b0;
end
```

**核心是这一句**：

```verilog
video_vs_d0 & ~video_vs
```

| 片段 | 含义 |
|---|---|
| `video_vs_d0` | vs 的**上一拍**值 |
| `~video_vs` | vs 的**当前**值取反 |
| 两者相与 | 上一拍是 1，这一拍是 0 → **下降沿** |

**术语**：**边沿检测（edge detection）**
- **上升沿** = `sig & ~sig_d0`
- **下降沿** = `sig_d0 & ~sig`

**为什么用下降沿发读请求**：vs 的边沿代表"一帧开始了/结束了"。在这一刻发起"读下一帧"，能保证读到的整帧数据是完整的、不会读到半帧。

### 块4：握手（第 68~71 行）

```verilog
else if(video_vs_d0 & ~video_vs)  read_req <= 1'b1;   // 拉高
else if(read_req_ack)             read_req <= 1'b0;   // 等应答后拉低
```

**术语**：**握手（handshake）**——`req` 拉高表示"我要"，对方做完拉高 `ack` 表示"好了"，然后 `req` 拉低。
**规则**：`req` 要保持到 `ack` 到来为止（不能只发一拍就走，否则慢的一方会漏掉）。

这套 `req / ack` 在第2站的 `frame_read_write` 里还会再见到一次。

---

## 三、⚠️ 这个文件被改过的地方

原来的（或者更早版本的）`video_timing_data.v` 里**也有数据通路**：

```verilog
//output                      read_en,       // 第 10 行，被注释
//input[DATA_WIDTH-1:0]       read_data,     // 第 11 行，被注释
//output[DATA_WIDTH-1:0]      vout_data      // 第 15 行，被注释
//assign read_en = video_de;                 // 第 29 行，被注释
// 第 53~63 行：整段数据寄存 always 被注释
```

**结论**：现在的 `video_timing_data.v` **只做两件事**：
1. 产生 hs / vs / de 时序
2. 在 vs 边沿发一拍 `read_req`

**数据通路（`read_en` → FIFO → `read_data` → `vout_data`）完全由 `video_delay.v` 承担。**

→ **这两个模块是"并行"的，不是串联的。** 所以：

| 模块 | 在链路里的位置 |
|---|---|
| `video_timing_data` | 只管"什么时候该显示第几个像素"（**时序**） |
| `video_delay` | 只管"把从 FIFO 读回的像素对齐到时序上"（**数据**） |

**这也解释了为什么两边的 `DATA_WIDTH` 一个 16 一个 24 却不要紧**——它们不串联，16 那个还是死参数。

---

## 四、能学到什么

1. **同步信号（hs/vs/de）的由来**：它们是"给显示器的路标"，告诉显示器什么时候换行、换帧、以及哪些像素是真的。
2. **边沿检测的两个标准写法**（上升沿 / 下降沿），以后会反复用到。
3. **握手协议 `req/ack`**：发请求 → 保持 → 等应答 → 撤销。
4. **复用现成模块只取一部分输出**（丢 RGB 留时序），比自己重写更稳。
5. **打拍**：输出前插一级寄存器，改善时序。

---

## 五、你们的实现会不会用这个电路？

**会用到其中的"部分"。**

| 参考工程的做法 | 建议你们 |
|---|---|
| 例化 `color_bar` 只取时序 | **可以继承这个思路**，但更干净的做法是**自己写一个 `video_timing_gen`**，只输出 hs/vs/de 和一个 `pixel_x / pixel_y` 坐标 |
| 两级延迟 | 保留（打拍是必须的） |
| 边沿检测发 `read_req` | 保留，但**建议改成"当前帧显示完、且下一帧已就绪"时才切换** |
| `read_req/ack` 握手 | 保留 |

**一个重要的建议**：**让时序模块同时输出当前像素坐标 `x, y`**。

为什么？因为你们后面要做"局部放大"——**放大就是把像素坐标做一次变换**再到源图里取数：
```
源图坐标 = (屏幕坐标 - 偏移) >> 缩放倍数
```
如果没有 `x, y`，这个运算就无从下手。

---

## 六、检查题

1. 为什么 hs/vs/de 要延迟 2 拍再输出，而不是直接用 `color_bar` 的输出？
2. 写出**上升沿**检测的表达式。（下降沿是 `sig_d0 & ~sig`）
3. `read_req` 如果用"只拉高一拍"的写法，会有什么问题？
4. 如果要加一个 `pixel_x / pixel_y` 输出，应该在哪里加、怎么算？

---

*上一站 → `第0站_上电脉冲_startup_pulse.md` ｜ 下一站 → `第2站_帧缓存读写_frame_read_write.md`*
