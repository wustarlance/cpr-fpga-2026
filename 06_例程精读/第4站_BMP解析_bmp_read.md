# 第4站：`bmp_read.v` —— BMP 解析

> 文件：`SD/bmp_read.v`（**322 行**）
> 💡 这一站有个**颠覆性发现**：参考工程**根本不用 FAT32**。详见第一节。

---

## 一、它在解决什么问题

从 SD 卡拿到的是**一串没有含义的字节**。这个模块干两件事：

| 任务 | 干什么 |
|---|---|
| **找** | 上电后扫描扇区，找出前 N 张 BMP 图片，记住它们的**扇区号** |
| **读** | 按指定扇区号，把一张图**逐像素**读出来，写进帧缓存 |

> **一句话：它把"字节流"变成"一行一行的 RGB 像素"。**

---

## 二、⚠️ 重大发现：这个工程**没有 FAT32**

### 证据

对全工程 `.v` 文件搜索 `fat / cluster / 目录项 / 文件系统`：

```bash
grep -rniE "fat|cluster|dir_entry" --include="*.v" .
```

**除了加密的 HDMI 核里那些随机 base64 串，一处都没有。**

### 那它怎么找图？

**按扇区扫描**。把每个 512 字节扇区的**开头几个字节**读出来，检查：

```verilog
assign header_match = (header_0 == "B") &&      // 第0字节是 'B'
                      (header_1 == "M") &&      // 第1字节是 'M'
                      (width[15:0]  == bmp_width)  &&   // 宽度对得上
                      (height[15:0] == bmp_height) &&   // 高度对得上
                      (bit_count    == 16'd24) &&       // 24 位色
                      (compression  == 32'd0);          // 不压缩
```

**六个条件全对 → 认为这个扇区是一张 BMP 的开头**，把扇区号记下来。

### 这对你们方案的影响（重要）

你们的方案（`心肺复苏训练终端_完整方案.md` 第 9.1 节）写的是：

| 模块 | 来源 |
|---|---|
| `sd_spi` + **`fat32`** | 参考工程改写 |

**但参考工程里没有 FAT32。** 这是个好消息，也是个需要现在就决定的事：

| | 用 FAT32（方案原写法） | 用扇区扫描（参考工程做法） |
|---|---|---|
| 要写的代码 | 目录项解析、簇链跟踪、8.3 短名、可能还有长文件名 | **几乎不用写**，照抄 |
| 图片怎么放 | **随便放**，按文件名找 | 必须放在**能被扫到的扇区范围**内，且**连续** |
| 换图操作 | 拷文件即可 | 需要按扇区位置烧写（或用工具保证连续） |
| 分辨率限制 | 无 | **必须与配置的宽高一致**（见第四节） |
| W2 工作量 | 大 | **小** |

**我的建议**：

> **W2 先用"扇区扫描"打通出图，把 FAT32 从 W2 里去掉。**
> 理由：W2 的目标是"屏幕显示第一张图"，不是"实现文件系统"。FAT32 可以放到 W7 或赛后作为升级项。
>
> 但**必须提前把"换图流程"想清楚**：如果四张教程图要能方便地更换，要么写个烧卡脚本固定位置，要么在屏幕上做一个"扫描进度"提示。

---

## 三、逐行读

### 块1：端口（第 1~36 行）—— 三组

**① SD 卡侧**（来自 `sd_card_top`）

```verilog
output reg        sd_sec_read;            // 请求读一个扇区
output reg [31:0] sd_sec_read_addr;       // 读哪个扇区
input      [7:0]  sd_sec_read_data;       // 扇区数据（一个字节一个字节来）
input             sd_sec_read_data_valid; // 这个字节有效
input             sd_sec_read_end;        // 这个扇区读完了
```

> **注意这里的数据宽度是 8 位**：SD 卡是**一个字节一个字节**吐出来的，不是一次给一个像素。

**② 上层控制**（来自 `sd_card_bmp`）

```verilog
input        scan_start;            // 开始扫描
input [31:0] scan_start_sector;     // 从哪个扇区开始扫
input [31:0] scan_max_sector;       // 扫到哪个扇区为止
input [2:0]  scan_target_count;     // 要找几张
output       scan_done;
output       scan_found_valid;      // 找到一个（脉冲）
output [31:0] scan_found_sector;
output [2:0]  scan_found_total;     // 一共找到几张

input        load_start;            // 开始加载
input [31:0] load_sector;           // 加载哪个扇区开始的图
```

**③ 输出**（送帧缓存）

```verilog
output reg        bmp_data_wr_en;   // 像素有效
output reg [23:0] bmp_data;         // 一个像素（24 位）
output reg        write_req;        // 请求写一帧
input             write_req_ack;
```

---

### 块2：字段寄存器（第 47~59 行）—— 对照 BMP 格式看

```verilog
reg [7:0]  header_0, header_1;
reg [31:0] file_len;        // 文件总长度
reg [31:0] pixel_offset;    // 像素数据从第几字节开始
reg [31:0] width, height;
reg [15:0] bit_count;       // 位深
reg [31:0] compression;     // 压缩方式
```

**BMP 文件头结构**（这就是这张表的全部依据）：

| 偏移 | 大小 | 字段 | 代码里的变量 |
|---|---|---|---|
| 0 | 2 | 签名 `"BM"` | `header_0/1` |
| **2** | 4 | 文件总长度 | `file_len` |
| 6 | 2 | 保留 | 不取 |
| 8 | 2 | 保留 | 不取 |
| **10** | 4 | **像素数据起始偏移** | `pixel_offset` |
| 14 | 4 | DIB 头大小（40） | 不取 |
| **18** | 4 | **宽度** | `width` |
| **22** | 4 | **高度** | `height` |
| 26 | 2 | 色彩平面数（1） | 不取 |
| **28** | 2 | **位深**（24） | `bit_count` |
| **30** | 4 | **压缩方式**（0=不压缩） | `compression` |
| 34 | 4 | 图像数据大小 | 不取 |

> **只有加粗的 7 个字段被取用**，其余跳过。**这就是"解析文件格式"的典型做法：只取你要的那几个字段，其余不管。**

---

### 块3：五条 `assign`（第 67~79 行）—— 全模块的精华

```verilog
assign ready = (state == ST_IDLE);

assign header_match = (header_0 == "B") && (header_1 == "M") &&
                      (width[15:0]  == bmp_width) &&
                      (height[15:0] == bmp_height) &&
                      (bit_count    == 16'd24) &&
                      (compression  == 32'd0);

assign bmp_data_valid = (sd_sec_read_data_valid == 1'b1) &&
                        (bmp_len_cnt >= pixel_offset) &&
                        (bmp_len_cnt <  file_len);
```

**重点看 `bmp_data_valid`——这是一条"地址过滤器"**：

| 条件 | 作用 |
|---|---|
| `sd_sec_read_data_valid` | SD 卡此刻确实给了一个字节 |
| `bmp_len_cnt >= pixel_offset` | **跳过文件头**（前 54 字节不是像素） |
| `bmp_len_cnt < file_len` | 不超过文件末尾 |

**三个条件相与 = "这个字节是真正的像素数据"。**

```verilog
assign file_sector_count = (file_len == 0) ? 1 : ((file_len + 511) >> 9);
assign next_scan_sector_if_match = scan_sector + file_sector_count;
assign next_scan_sector_if_miss  = scan_sector + 1;
```

**这两条是"跳着扫"的优化**：

- **命中**：说明找到一张图，下一张要从 `当前扇区 + 这张图占多少扇区` 开始找 → **跳过整张图**，不用逐扇区扫
- **未命中**：这张不是图，**往后挪一个扇区**继续找

**术语**：`>> 9` 就是 **÷512**（2⁹ = 512），即"字节数 → 扇区数"。**用移位代替除法**，硬件里只用连线，不消耗资源。

> ⚠️ 这里有个细节：`file_sector_count` 用 `file_len` 算，而 `file_len` 是在**扫到这张图时才刚读出来的**。所以第一次扫描时 `file_len` 可能是上一张的残留值——但只影响"跳多远"，命中判断本身没问题。**这是个可以改进的地方**（见第五节）。

---

### 块4：按偏移量拼头字段（第 94~139 行）

```verilog
always @(posedge clk or posedge rst) begin
    if (rst) begin
        ...
    end else if (((state == ST_SCAN) || (state == ST_LOAD_HDR)) && sd_sec_read_data_valid) begin
        case (rd_cnt)
            10'd0 : header_0 <= sd_sec_read_data;
            10'd1 : header_1 <= sd_sec_read_data;

            10'd2 : file_len[7:0]   <= sd_sec_read_data;
            10'd3 : file_len[15:8]  <= sd_sec_read_data;
            10'd4 : file_len[23:16] <= sd_sec_read_data;
            10'd5 : file_len[31:24] <= sd_sec_read_data;
            ...
            10'd18: width[7:0] <= sd_sec_read_data;
            ...
        endcase
    end
end
```

**核心思路**：`rd_cnt` 是"当前扇区里第几个字节"（第 81~92 行维护）。

于是**"第几个字节"直接对应到"哪个字段的第几位"**：

```
offset 2 → file_len[7:0]        ┐
offset 3 → file_len[15:8]       │ BMP 存的是小端
offset 4 → file_len[23:16]      │ （低位字节在前）
offset 5 → file_len[31:24]      ┘
```

**术语卡**

| 术语 | 意思 |
|---|---|
| **小端（little-endian）** | 低位字节存在低地址。BMP 就是小端，所以第 2 字节是 `file_len[7:0]` |
| **偏移量（offset）** | 从文件开头数第几个字节 |
| **case 按计数器分派** | 用"第几个字节"决定"往哪塞"，是解析定长头部最直接的写法 |

---

### 块5：两个计数器（第 141~161 行）

```verilog
// ① bmp_len_cnt：从文件开头算起，已经读了多少字节
always @(posedge clk or posedge rst)
    if (rst) bmp_len_cnt <= 0;
    else if (state == ST_LOAD_DATA) begin
        if (sd_sec_read_data_valid) bmp_len_cnt <= bmp_len_cnt + 1;
    end else bmp_len_cnt <= 0;

// ② bmp_byte_idx：0→1→2→0 循环，用来把 3 个字节拼成一个像素
always @(posedge clk or posedge rst)
    if (rst) bmp_byte_idx <= 0;
    else if (state == ST_LOAD_DATA) begin
        if (bmp_data_valid) bmp_byte_idx <= (bmp_byte_idx == 2) ? 0 : bmp_byte_idx + 1;
    end else bmp_byte_idx <= 0;
```

> **注意区别**：`bmp_len_cnt` 数**每一个** SD 字节；`bmp_byte_idx` 只在**有效像素字节**上转。
> 前者用来"判断是不是在像素区"，后者用来"三个字节拼一个像素"。

---

### 块6：3 字节拼 1 像素（第 163~192 行）

```verilog
if (bmp_data_valid) begin
    case (bmp_byte_idx)
        2'd0: begin bmp_data_wr_en <= 1'b0;  bmp_data[7:0]   <= sd_sec_read_data; end
        2'd1: begin bmp_data_wr_en <= 1'b0;  bmp_data[15:8]  <= sd_sec_read_data; end
        2'd2: begin bmp_data_wr_en <= 1'b1;  bmp_data[23:16] <= sd_sec_read_data; end
    endcase
end
```

**BMP 里一个像素是 3 个字节，顺序是 B、G、R。** 代码按到达顺序塞进低→高：

| 到达顺序 | 存到 | 实际颜色 |
|---|---|---|
| 第 1 个 | `bmp_data[7:0]` | **B**（蓝） |
| 第 2 个 | `bmp_data[15:8]` | **G**（绿） |
| 第 3 个 | `bmp_data[23:16]` | **R**（红） |

→ 拼好的 `bmp_data` 就是 `{R, G, B}`，**正好是 RGB888 顺序**，和后面显示链路对得上。

**关键技巧**：**第 3 个字节到齐的那一拍才拉高 `bmp_data_wr_en`** —— 保证下游拿到的永远是完整像素。

---

### 块7：主状态机（第 194~322 行）—— 全模块的"大脑"

#### 7.1 骨架：三段前置判断

```verilog
always @(posedge clk or posedge rst) begin
    if (rst)                     ... 全部清零
    else if (!sd_init_done)      ... 也全部清零      ← 第二道闸
    else begin
        scan_found_valid <= 1'b0;                    // ← 默认清零（关键）
        case (state)
            ST_IDLE / ST_SCAN / ST_LOAD_HDR / ST_LOAD_WAIT / ST_LOAD_DATA / default
        endcase
    end
end
```

**① `scan_found_valid <= 1'b0;` 写在 `case` 前面**

```verilog
scan_found_valid <= 1'b0;                       // 默认清零
...
if (header_match) scan_found_valid <= 1'b1;     // 命中那一拍才拉高
```

**和第0站 `startup_pulse` 里的 `O_pulse <= 1'b0;` 是同一个技巧**——"默认清零 + 条件置 1" = **单拍脉冲**。

> 所以 `scan_found_valid` 只高**一个时钟周期**，是"打点"的线，**不能当电平用**。
> 用它的地方（`sd_card_bmp` 第 192 行 `if (scan_found_valid)`）是**边沿式**写法，方向是对的。

**② `else if (!sd_init_done)` 是"第二道闸"**

SD 卡没初始化完，状态机不许动、输出全清。
→ **使能门控 / 互锁**：上游没准备好，下游保持复位。

#### 7.2 状态图

```
                    ┌──────────────────────────────────┐
                    │                                  │
                    ▼                                  │
              ┌──────────┐                             │
       ┌─────▶│ ST_IDLE  │                             │
       │      └────┬─────┘                             │
       │           │                                   │
       │  scan_start│        load_start               │
       │           ▼             ▼                     │
       │     ┌──────────┐   ┌──────────────┐           │
       │     │ ST_SCAN  │   │ ST_LOAD_HDR  │           │
       │     └────┬─────┘   └──────┬───────┘           │
       │          │                │ header ok         │
       │   找够/扫到边界      header bad → 直接回 IDLE  │
       │          │                ▼                   │
       │          │         ┌──────────────┐           │
       │          │         │ ST_LOAD_WAIT │ 等 ack    │
       │          │         └──────┬───────┘           │
       │          │                ▼                   │
       │          │         ┌──────────────┐           │
       │          │         │ ST_LOAD_DATA │ 逐扇区搬   │
       │          │         └──────┬───────┘           │
       │          │      读完 file_len 字节             │
       └──────────┴────────────────┴───────────────────┘
```

#### 7.3 逐状态讲

**`ST_IDLE`（223~239）—— 等两个启动信号**

```verilog
if (scan_start) begin
    scan_sector      <= scan_start_sector;
    sd_sec_read_addr <= scan_start_sector;
    state            <= ST_SCAN;
end else if (load_start) begin
    load_sector_latched <= load_sector;      // ← 锁存！
    sd_sec_read_addr    <= load_sector;
    state               <= ST_LOAD_HDR;
end
```

**为什么要 `load_sector_latched` 多存一份**：`load_sector` 是**外面给的**，可能在传输过程中变化（外面可能已经在准备下一张）。**锁存一份自己用**是接口设计的标准习惯——**不要直接拿外部输入做长时间的运算**。

**`ST_SCAN`（241~272）—— 逻辑最重的一段**

```verilog
sd_sec_read <= 1'b1;                 // 持续请求读扇区
if (sd_sec_read_end) begin           // 一个扇区读完
    sd_sec_read <= 1'b0;
    if (header_match) begin          // ① 命中
        scan_found_valid  <= 1'b1;             // 打点通知外面
        scan_found_sector <= scan_sector;      // 告诉外面"图在这"
        scan_found_total  <= scan_found_total + 1;
        ...
    end else begin ... end           // ② 未命中
end
```

两条分支各自还要判断"要不要收工"：

| 分支 | 收工条件 | 否则 |
|---|---|---|
| **命中** | 找够了（`scan_found_total+1 >= scan_target_count`）**或** 下一张会超出 `scan_max_sector` | `sd_sec_read_addr <= 下一张的候选位置`（**跳过整张图**） |
| **未命中** | `scan_sector >= scan_max_sector`（扫到边界） | `sd_sec_read_addr <= 当前+1`（**往后挪一个扇区**） |

> **`scan_found_sector <= scan_sector;` 用的是"旧值"**——因为 `<=` 是非阻塞赋值，右边读的是这一拍的值。
> 所以它准确记下了**这张图的开头**，而不是"下一张的候选位置"。**这点写错就全错。**

**还有一个细节**：`sd_sec_read` 在 `sd_sec_read_end` 那一拍被清 0，下一拍又被 `case` 开头重新拉高 → **中间拉低一拍**。
这一拍是给 `sd_card_top` 的"这次读完了"的边界，然后重新发起一次新的扇区读。**是"读—停—读"的节拍，不是 bug。**

**`ST_LOAD_HDR`（274~288）—— 只为了验证文件头**

```verilog
sd_sec_read <= 1'b1;
if (sd_sec_read_end) begin
    sd_sec_read <= 1'b0;
    if (header_match) begin
        write_req        <= 1'b1;                     // 申请写权限
        sd_sec_read_addr <= load_sector_latched;      // 退回文件头
        state            <= ST_LOAD_WAIT;
    end else begin
        state <= ST_IDLE;                             // 不是图，放弃
    end
end
```

**为什么单独设一个状态**：因为**加载前必须先确认"这个扇区确实是一张图"**。`load_sector` 是外部给的，可能给错；扫描也可能因为"找够了"提前结束。**不验就搬数据是危险的。**

**`sd_sec_read_addr <= load_sector_latched` 干什么**：刚才为了验头已经把这个扇区读了一遍，现在**退回去重新读**，这样 `ST_LOAD_DATA` 里 `bmp_len_cnt` 才能**从 0 开始**正确计数。

**`ST_LOAD_WAIT`（290~296）—— 等对方准备好**

```verilog
if (write_req_ack) begin
    write_req <= 1'b0;         // 撤销请求
    state     <= ST_LOAD_DATA;
end
```

**握手是必要的**：`write_req` 发给**帧缓存写入侧**，对方收到后要做事（切缓冲区、清 FIFO），得花时间。**不等 ack 就灌数据，数据会丢。**

**标准四拍握手**：

```
① 发起方：req = 1
② 接收方：看到 req，准备，ack = 1
③ 发起方：看到 ack，req = 0
④ 接收方：看到 req = 0，ack = 0
```

这里实现了 ①②③（简化版，没等 ④）。和第1站的 `read_req/read_req_ack` 是**同一套机制**，只是那次是"我要读"，这次是"我要写"。

**`ST_LOAD_DATA`（298~310）—— 搬数据**

```verilog
sd_sec_read <= 1'b1;
if (sd_sec_read_end) begin
    sd_sec_read <= 1'b0;
    if (bmp_len_cnt >= file_len) begin
        state <= ST_IDLE;                              // 搬完了
    end else begin
        sd_sec_read_addr <= sd_sec_read_addr + 32'd1;  // 下一个扇区
    end
end
```

**看清楚：这个状态自己不算像素、不拼字节、不输出数据。它只决定"读哪个扇区"。**

**`default`（312~317）—— 兜底**

```verilog
default: begin
    state       <= ST_IDLE;
    state_code  <= 4'd1;
    sd_sec_read <= 1'b0;
    write_req   <= 1'b0;
end
```

**写状态机永远要写 `default`。** 万一 `state` 被打成非法值（噪声、仿真初始态），没有 `default` 就会**永远卡死**；有了它下一拍自动回 IDLE。

#### 7.4 最重要的组织思想：控制器 / 数据通路分离

| 谁 | 负责什么 |
|---|---|
| **本 always（块7）** | **控制器**：决定"读哪个扇区、什么时候停" |
| **块5 + 块6** | **数据通路**：把字节拼成像素、输出 |

**状态机里一行拼像素的代码都没有**——它只管"发号施令"。这是数字设计最核心的组织思想之一：**把"做什么"和"怎么算"分成两块写，两边都好改、也好验。**

#### 7.5 两处可以改进的地方

**① `scan_sector` 和 `sd_sec_read_addr` 始终同值 —— 冗余**

| 位置 | `scan_sector` | `sd_sec_read_addr` |
|---|---|---|
| `ST_IDLE`（scan） | `scan_start_sector` | `scan_start_sector` |
| `ST_SCAN` 命中 | `next_..._if_match` | `next_..._if_match` |
| `ST_SCAN` 未命中 | `next_..._if_miss` | `next_..._if_miss` |

**三处都赋成同一个值**，所以扫描期间两个寄存器**永远相等** → 可以合并成一个。

> 保留两个的好处是**语义清楚**（一个表示"当前扫到哪"，一个表示"接下来读哪"），代价是多一份寄存器。**属于可接受的冗余，但要知道它是冗余的。**

**② `state_code` 有重号 —— 调试信息丢失**

| 状态 | `state_code` |
|---|---|
| `ST_IDLE` | 1 |
| **`ST_SCAN`** | **2** |
| **`ST_LOAD_HDR`** | **2** ← 重号！ |
| `ST_LOAD_WAIT` | 3 |
| `ST_LOAD_DATA` | 4 |

`state_code` 是拿去给数码管显示的（调试用）。**SCAN 和 LOAD_HDR 都是 2**，上板调试时**分不出"卡在扫描"还是"卡在验头"**。

→ **建议改成 1/2/3/4/5**。上板卡住时，这个号就是第一手线索。

---

## 四、四个额外的细节（值得看）

### 细节1：`bmp_data_valid` 只取像素区——"地址过滤"

文件头（前 54 字节）不是像素，必须跳过。代码用**区间判断**来完成：

```verilog
(bmp_len_cnt >= pixel_offset) && (bmp_len_cnt < file_len)
```

比"记住已经跳过多少字节"更简单，也更不容易错。

### 细节2：⚠️ **图片宽度必须是 4 的倍数**

BMP 规定**每一行的字节数必须补齐到 4 的倍数**。

比如宽 641 的图：641 × 3 = 1923 字节，要补到 1924 —— **行末多出 1 个填充字节**。

而这份代码**完全没有处理填充**：它只用 `bmp_len_cnt < file_len` 判断，填充字节也落在这个区间里，会被 `bmp_byte_idx` 当成像素 → **每行错位，画面斜掉**。

**什么时候没事**：`width × 3` 能被 4 整除。因为 `gcd(3,4)=1`，所以等价于 **`width` 能被 4 整除**。

| 宽度 | 640 | 800 | 1024 | 1280 | 641 | 500 |
|---|---|---|---|---|---|---|
| 是否安全 | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ |

→ **你们做素材时，图片宽度务必选 4 的倍数**（640 / 800 / 1024 都安全）。这条要写进素材规范。

### 细节3：24 → 32 的打包（和顶层 `[31:8]` 闭环）

`bmp_data` 是 24 位，但帧缓存写侧是 **32 位**。转换在 `sd_card_bmp.v` 里：

```verilog
assign write_data = {bmp_data[23:16], bmp_data[15:8], bmp_data[7:0], 8'b0};
//                    └── R ──┘        └── G ──┘        └── B ──┘   └ 补8个0 ┘
```

**24 位塞进高 24 位，低 8 位补 0。**

→ 这正好解释了**第3站细节2**里顶层的 `video_read_data[31:8]`：读回来时把低 8 位丢掉，取回 24 位 RGB。

**一条链路闭环了**：BMP 的 BGR → `bmp_data{R,G,B}` → 左移 8 位存 32 位 → 读回取 `[31:8]` → HDMI。

### 细节4：`header_match` 要求宽高**精确匹配**

```verilog
(width[15:0] == bmp_width) && (height[15:0] == bmp_height)
```

`bmp_width` / `bmp_height` 是模块的**输入**。也就是说：

> **扫描时只会认出"和当前配置尺寸完全一致"的图。**

| 影响 | 说明 |
|---|---|
| ✅ 好处 | 扫描更准，不会把别的数据误认成图 |
| ⚠️ 代价 | **所有图片必须是同一个分辨率**；想用不同尺寸的图，得先改配置再扫 |

对你们的四张教程图：**统一做成同一尺寸**（建议 640×480 或 800×600）就没问题。
但方案里扩展③写了"不同分辨率图适配"——**这一条要提前规划**：要么所有图统一尺寸（简单），要么改成支持多尺寸扫描。

---

## 五、一个"坏味道"（要能识别出来）

**魔数**：`2/3/4/5`、`10/11/12/13`、`18/19/20/21`、`22/23/24/25`、`28/29`、`30/31/32/33` 这一堆偏移量**在代码里没有任何说明**。

它们当然是有出处的——**BMP 文件头格式**（见块2那张表）。但代码里没写。

**判断标准**：换一种图片格式（比如 PNG 或自定义格式），你需不需要重新查一遍？**需要 → 就该在代码里留一张偏移表，或者至少写注释。**

**另外一处可以改进的**：`file_sector_count` 依赖 `file_len`，而 `file_len` 在**第一次扫描时**还是上一次的残留值（甚至是复位后的 0）。建议在 `ST_SCAN` 读到头部后，**用一个只在命中时才使用的寄存器**来算跳转距离。

---

## 六、能学到什么

1. **解析定长文件头的套路**：认签名 → 按偏移取字段 → 其余跳过。
2. **小端拼装**：低位字节在低地址，拼的时候注意顺序。
3. **N 字节拼一个宽数据**：`byte_idx` 循环 + **最后一个字节到齐时拉 wr_en**。这个模式以后解析任何二进制格式都用得上。
4. **用移位代替除法**：`>> 9` 就是 ÷512。硬件里除法很贵，能移就移。
5. **地址区间过滤**：用"计数落在某个区间内"来筛选有效数据，比记状态简单。
6. **两层握手**：上层要数据（`write_req/ack`）、下层给数据（`sd_sec_read_data_valid/end`）——**两个方向的流控**。

---

## 七、你们的实现会不会用这个电路？

### 结论：**会用到，而且是整条 SD 链路里你们最需要的一段。可以整段搬，但有 3 处必改、1 个架构决策要先定。**

你们的方案里这个模块叫 **`bmp_decode`**。

### 7.1 可以直接整段搬的部分（改参数就行）

| # | 内容 | 为什么能直接用 |
|---|---|---|
| 1 | **五状态骨架** + `default` 兜底 | 流程通用：找图 → 验头 → 握手 → 搬数据 |
| 2 | **头部字段解析**（`rd_cnt` + `case` 拼字段） | BMP 格式固定，偏移量不会变 |
| 3 | **扇区扫描六条件** | 你们也是"扫出几张图" |
| 4 | **3 字节拼 1 像素**（`bmp_byte_idx` 循环） | 24 位色 BMP 通用 |
| 5 | **控制器 / 数据通路分离**的写法 | 组织思想，与场景无关 |
| 6 | **`write_req / ack` 握手** | 接帧缓存必须做 |

### 7.2 必须改的三处

| # | 改什么 | 怎么改 |
|---|---|---|
| 1 | **`bmp_width` / `bmp_height`** | 传你们的分辨率（建议四张图统一 **640×480** 或 **800×600**） |
| 2 | **`SCAN_TARGET_COUNT`** | 参考工程默认 4。**你们如果还要加载标注图，就不止 4 张**——先数清楚要几张 |
| 3 | **`state_code` 重号** | `ST_SCAN` 和 `ST_LOAD_HDR` 都是 2，**上板调试分不清卡在哪**。改成 1/2/3/4/5 |

> 另外**不是改代码、是改素材规范**：图片宽度取 **4 的倍数**（见细节2）。

### 7.3 ⚠️ 一个必须先定的架构问题：多图层怎么叠

**参考工程是「一次加载一张图 → 双缓冲切换」。而你们的方案要「底图 + 标注层叠加」——两张图要同时在帧缓存里。参考工程不直接支持。**

三条路，各有代价：

| 方案 | 做法 | 优点 | 代价 |
|---|---|---|---|
| **A. 预合成** | 把标注画进图里，做成「有标注版 / 无标注版」两张图，按键切换 | **零改动，直接搬** | 「图层叠加」退化成「图片切换」，**扩展① 的说服力弱** |
| **B. 双读通道** | 帧缓存里放底图 + 标注图两块，读侧**加一路读**（第二个 rfifo + `frame_fifo_read`），像素级合成 | **真正的图层叠加** | 要改 `frame_read_write` 读侧；SDRAM 带宽翻倍（2×18.4M×4B ≈ **147 MB/s**，而 125MHz×32bit = 500 MB/s，**够用**） |
| **C. 标注常驻 BSRAM** | 标注做成 **1 位掩码**存片内 BSRAM（640×480 只要 **38.4 KB**，总 136 KB 装得下），读侧查表叠加 | **不动 SDRAM 读侧，带宽不变** | 标注只能是「单色 + 掩码」，不能是彩色图；要生成 BSRAM 初始化文件 |

**我的建议**：

| 时间 | 做什么 |
|---|---|
| **W3~W4** | **先用 A**，保证模式①按时跑起来（"能交作品"是 W4 的硬目标） |
| **W5** | 如果时间允许，再升级到 **C**（改动小、带宽不变），把扩展①做实 |

> 💡 **还有一条更轻的路子**：标注如果只是"几个框 + 几条线 + 刻度"，可以**不存图**，改成在硬件里**用矩形发生器实时画**（"这个坐标在不在第 N 个矩形内" = 几个比较器）。
> 这样既省资源，**又是货真价实的"实时生成图层"**——比存预制图更贴合扩展①的本意。代价是标注的形状要重新用参数描述一遍。

### 7.4 和排期的对接

| 周 | 你们方案里写的 | 建议调整 |
|---|---|---|
| **W2** | B：FAT32 + BMP 解析 | **改为：SD 卡 SPI 通 + 扇区扫描 + BMP 解析**（去掉 FAT32，W2 省一大块） |
| W7 或赛后 | — | FAT32 作为升级项，或者写个"烧卡脚本"把图片固定到连续扇区 |

### 7.5 关于「复用参考工程已有的扫描结果」

参考工程里 `sd_card_bmp` **内部已经实现好了**这样一套逻辑：

```verilog
wire [31:0] scan_found_sector;     // ← bmp_read 的输出：每找到一张就脉冲一次
reg  [31:0] img_sector0/1/2/3;     // ← 扫描时按顺序存进这 4 个格子
reg  [2:0]  img_found_count;       // ← 实际找到几张
function [31:0] sector_lut(idx);   // ← 给编号，返回扇区号（4 选 1 多路器）
```

**也就是说：「扫描 → 记下每张图在哪 → 按编号查出来加载」这套逻辑不用你们重写。**

但要注意一点——**这四个 `img_sectorN` 是模块内部的 `reg`，不是输出端口**，所以"接出来"取决于你们走哪条路：

| 你们的做法 | 需要做什么 |
|---|---|
| **直接复用 `sd_card_bmp`** | **什么都不用做**，它自己会用（按键翻页、自动轮播都靠 `sector_lut`） |
| **自己写类似模块** | 照抄这段写法：扫描时按序填表，用时用 `function` 按索引取 |
| **要在顶层看到"扫描结果"**（比如屏幕上显示"扫描 3/4"） | **这才需要真的接出来**——把那几个 `reg` 改成 `output` 端口 |

---

## 八、检查题（答完进第5站）

1. BMP 文件头里"像素数据起始偏移"在第几个字节？代码用什么变量接的？
2. `bmp_data_valid` 的三个条件分别排除了什么？如果去掉 `bmp_len_cnt >= pixel_offset` 会怎样？
3. 为什么 `bmp_data_wr_en` 只在 `bmp_byte_idx == 2` 那一拍拉高？
4. 为什么图片宽度必须是 4 的倍数？如果用了 641 宽会看到什么现象？
5. `>> 9` 为什么等于除以 512？如果换成 `>> 10` 是什么意思？
6. （承上，与第3站联动）`write_data = {bmp_data[23:16], bmp_data[15:8], bmp_data[7:0], 8'b0}` —— 为什么低 8 位补 0？这和第3站顶层那个 `[31:8]` 是什么关系？
7. （结合你们方案）如果四张教程图里混了一张 800×600、三张 640×480，扫描会发生什么？

---

*上一站 → `第3站_读延迟补偿_video_delay.md` ｜ 下一站 → `第5站_SD卡SPI链路.md`（待讲）*
