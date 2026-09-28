# 第0站：`startup_pulse.v` —— 上电后发一个"单拍脉冲"

> 文件：`src/user_source/hdl_source/startup_pulse.v`（35 行）
> 顶层用法：
> ```verilog
> // 上电后自动打一拍，触发一次 EDID 读取
> startup_pulse #( .CNT_MAX(20'd100000) ) u_startup_pulse (
>     .I_clk   (video_clk),     // 25 MHz
>     .I_rst   (rst_all),
>     .O_pulse (edid_trig)
> );
> ```

---

## 一、它在解决什么问题

FPGA 一上电，各模块需要一点时间才稳定。所以需要一个模块：

> **上电后先数一段时钟，数到了就发一个"只持续一拍"的脉冲**，去触发一次性动作。

在顶层里这个脉冲接的是 **`edid_trig`** —— 触发**一次 EDID 读取**（读显示器的能力信息）。

**时间算一下**：

| 项 | 值 |
|---|---|
| `CNT_MAX` | 100000 |
| 时钟 | `video_clk` = 25 MHz |
| 时间 | 100000 ÷ 25,000,000 = **4 毫秒** |

→ **上电 4ms 后，发一个单拍脉冲去读一次 EDID。**

---

## 二、逐行读

```verilog
module startup_pulse #(
    parameter [19:0] CNT_MAX = 20'd100000
)(
    input  wire I_clk,
    input  wire I_rst,
    output reg  O_pulse
);

reg [19:0] S_cnt;
reg        S_done;
```

**术语卡**

| 术语 | 意思 |
|---|---|
| `[19:0]` | 20 位宽，最大能表示 2²⁰−1 = **1,048,575** |
| `20'd100000` | `d` = 十进制；这是"20 位宽的十进制数 100000" |
| `S_` / `I_` / `O_` 前缀 | 编码风格：`S_`=状态寄存器，`I_`=输入，`O_`=输出 |

```verilog
always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        S_cnt   <= 20'd0;
        S_done  <= 1'b0;
        O_pulse <= 1'b0;
    end
    else begin
        O_pulse <= 1'b0;          // ← 关键行
        if (!S_done) begin
            if (S_cnt == CNT_MAX - 1'b1) begin
                S_cnt   <= S_cnt;      // 数到顶就保持，不再数
                S_done  <= 1'b1;       // 锁存"已完成"
                O_pulse <= 1'b1;       // 只在这一拍拉高
            end
            else begin
                S_cnt <= S_cnt + 1'b1;
            end
        end
    end
end
```

### 三个设计要点

**① 单拍脉冲怎么写**

`O_pulse <= 1'b0;` 写在 `always` 的**最前面**，后面的条件赋值会**覆盖**它。
→ 默认输出 0，只有命中条件那一拍才是 1。**这就是"单拍脉冲"的标准写法。**

**术语**：**单拍脉冲（one-cycle pulse）**——外设通常只想看到"一个时钟周期的有效"，而不是持续的高电平。

**② 只触发一次**

`S_done` 一旦置 1，`if (!S_done)` 就永远不成立，计数器停住。
→ **保证只有一个脉冲**，不会周期性重复。

**③ 计数器不清零**

`S_cnt <= S_cnt;` 数到顶就保持原值（不清 0）。
→ 既省电，也避免万一逻辑出错又从头数。

---

## 三、能学到什么

1. **"默认赋 0 + 条件赋 1"** 是产生单拍脉冲的标准写法，以后会反复用到。
2. **一次性（one-shot）逻辑**用"完成标志锁存"实现，而不是靠外部清计数器。
3. **参数化计数**：`CNT_MAX` 是参数，例化时传不同值就能改变延时。

---

## 四、你们的实现会不会用这个电路？

**会用到这个"思路"，但不建议照抄实现。**

| 参考工程 | 建议你们 |
|---|---|
| 固定数 100000 拍（4ms）后发脉冲 | **等所有 PLL 的 `lock` 信号都有效 + SDRAM `init_done`** 再放开复位 |
| 只用于触发 EDID | 也用于解除全系统的 `rst` |

**为什么**：固定计数的假设是"4ms 内 PLL 一定锁好了"。但仿真时、不同温度下、换一块板子时，这个假设不一定成立。**真实工程里叫 reset sequencer（复位序列器）**——按"条件"而不是"时间"来放行。

参考写法（思路）：

```verilog
// 等所有 PLL 锁定，再放开复位
reg [3:0] rst_cnt = 0;
always @(posedge clk) begin
    if (!pll_locked)                  rst_cnt <= 0;
    else if (rst_cnt != 4'hF)         rst_cnt <= rst_cnt + 1;
end
assign rst_n = (rst_cnt == 4'hF);
```

---

## 五、检查题

1. 如果把 `O_pulse <= 1'b0;` 这一行去掉，输出会变成什么样？
2. `S_cnt <= S_cnt;` 改成 `S_cnt <= 20'd0;` 会怎样？还能保证只发一个脉冲吗？
3. `CNT_MAX` 改成 20'd25000，延时变成多少毫秒？
4. 为什么这个模块用 `video_clk`（25MHz）而不是 `mem_clk`（125MHz）来计时？（提示：看它接的是谁）

---

*下一站 → `第1站_视频时序_video_timing_data.md`*
