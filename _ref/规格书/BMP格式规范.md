# BMP 文件格式规范（官方文档整理 + 与 `bmp_read.v` 逐字节对照）

> 整理日期：2026-09-20
> 用途：心肺复苏训练终端 · W2 素材规范；以及第4站 `bmp_read.v` 的格式依据
> **全部字段定义来自微软官方文档**（链接见文末），并已用厂商的真实 BMP 文件实测核对

---

## 〇、一句话

BMP 是最简单的图片格式：**文件头（14 B）+ 信息头（40 B）+ [调色板/颜色掩码] + 像素数据**。
24 位无调色板时，**像素数据从第 54 字节开始**，且**每行按 4 字节对齐**（这条决定了"宽度必须是 4 的倍数"）。

---

## 一、官方文档在哪

| 资料 | 链接 | 讲什么 |
|---|---|---|
| ⭐ **`BITMAPFILEHEADER` 结构** | [learn.microsoft.com/…/ns-wingdi-bitmapfileheader](https://learn.microsoft.com/zh-cn/windows/win32/api/wingdi/ns-wingdi-bitmapfileheader) | 文件头 14 字节的逐字段定义 |
| ⭐ **`BITMAPINFOHEADER` 结构** | [learn.microsoft.com/…/ns-wingdi-bitmapinfoheader](https://learn.microsoft.com/zh-cn/windows/win32/api/wingdi/ns-wingdi-bitmapinfoheader) | 信息头 40 字节的逐字段定义 + **行距（stride）公式** + **`biHeight` 符号规则** |
| ⭐ **位图存储（Bitmap Storage）** | [learn.microsoft.com/…/gdi/bitmap-storage](https://learn.microsoft.com/zh-cn/windows/win32/gdi/bitmap-storage) | **整体文件布局** + 一个真实 BMP 的**完整十六进制 dump**（可直接当对照样本） |
| `BITMAPINFOHEADER`（视频语义版） | [同上](https://learn.microsoft.com/zh-cn/windows/win32/api/wingdi/ns-wingdi-bitmapinfoheader) | 同一结构的另一种说明角度（BMP **不是**用来描述视频的，看上面那篇即可） |
| `BITMAPV4HEADER` / `BITMAPV5HEADER` | [learn.microsoft.com](https://learn.microsoft.com/zh-cn/windows/win32/gdi/bitmap-header-types) | 扩展头（108 / 124 字节）。**本工程用不到**，但要知道它们存在（见第五节） |

> 💡 官方**没有再单独发布一份"BMP 格式 PDF 规范"** —— 这份格式的权威定义就是上面这几篇结构说明（Windows GDI/DirectShow 文档）。网上流传的 "Microsoft Windows Bitmap File Format" 老 PDF 是 Windows 3.x SDK 时代的，内容与之一致。

---

## 二、整体布局

来自《位图存储》官方原文："已建立的位图文件格式包括 `BITMAPFILEHEADER` 结构，后跟 `BITMAPINFOHEADER`、`BITMAPV4HEADER` 或 `BITMAPV5HEADER` 结构。`RGBQUAD` 结构的数组（也称为颜色表）遵循位图信息标头结构。颜色表后跟……实际位图数据。"

```
┌──────────────────────────────┐ 偏移 0
│  BITMAPFILEHEADER  (14 字节)  │
├──────────────────────────────┤ 偏移 14
│  BITMAPINFOHEADER  (40 字节)  │   ← 也可能是 V4(108)/V5(124) 头
├──────────────────────────────┤ 偏移 54
│  调色板 RGBQUAD[] 或颜色掩码   │   ← 24 位 BI_RGB 时**没有**这一段
├──────────────────────────────┤ 偏移 bfOffBits
│  像素数据（自下而上或自上而下） │
└──────────────────────────────┘
```

**24 位无压缩（本工程的情形）：`bfOffBits = 14 + 40 = 54`，中间没有调色板。**

> 官方 dump 里的 `Redbrick.bmp` 是个 **4 位**（16 色）图，所以它有 16×4 = 64 字节调色板：
> `bfOffBits = 0x76 = 118 = 54 + 64`。**这正好演示了"`bfOffBits` 必须从文件里读、不能写死 54"** —— `bmp_read.v` 就是这么做的（见第五节）。

---

## 三、`BITMAPFILEHEADER`（偏移 0~13，共 14 字节）

| 偏移 | 大小 | 字段 | 官方说明 | 本工程实测值 |
|---|---|---|---|---|
| **0** | 2 | **`bfType`** | "文件类型；**必须 `0x4d42`**（ASCII 字符串 "BM"）" | `0x4D42` = 'BM' ✅ |
| **2** | 4 | **`bfSize`** | "位图文件的大小（以字节为单位）" | `921654` |
| 6 | 2 | `bfReserved1` | "保留；**必须为零**" | `0` ✅ |
| 8 | 2 | `bfReserved2` | "保留；**必须为零**" | `0` ✅ |
| **10** | 4 | **`bfOffBits`** | "从 `BITMAPFILEHEADER` 结构开头到**位图位**的偏移量（以字节为单位）" | `54` ✅ |

多字节字段都是**小端（little-endian）**：低字节在前。`bmp_read.v` 的拼装顺序与之吻合（第 2 字节 → `[7:0]`，第 5 字节 → `[31:24]`）。

---

## 四、`BITMAPINFOHEADER`（偏移 14~53，共 40 字节）

| 偏移 | 大小 | 字段 | 官方说明（摘） | 本工程实测值 |
|---|---|---|---|---|
| **14** | 4 | `biSize` | "结构所需的字节数"（简化版 = 40） | `40` |
| **18** | 4 | **`biWidth`** | 宽度（像素） | `640` |
| **22** | 4 | **`biHeight`** | 高度（像素）；**符号决定行序**（见下） | `+480` |
| 26 | 2 | `biPlanes` | "**必须设置为 1**" | `1` ✅ |
| **28** | 2 | **`biBitCount`** | 每像素位数 | `24` |
| **30** | 4 | **`biCompression`** | `BI_RGB`(=0) 未压缩 / `BI_BITFIELDS`(=3) 带掩码 | `0` ✅ |
| 34 | 4 | `biSizeImage` | 图像大小（字节）；未压缩 RGB "可以将其设置为 0" | `921600` |
| 38 | 4 | `biXPelsPerMeter` | 水平分辨率（像素/米） | `0` |
| 42 | 4 | `biYPelsPerMeter` | 垂直分辨率 | `0` |
| 46 | 4 | `biClrUsed` | 调色板实际使用数 | `0` |
| 50 | 4 | `biClrImportant` | 重要颜色数 | `0` |

### 4.1 ⭐ 行距（stride）——"宽度必须是 4 的倍数"的官方出处

官方原文："对于未压缩的 RGB 格式，**最小步幅始终是图像宽度（以字节为单位），向上舍入到最接近的 DWORD**"，并给出公式：

```
stride = ((((biWidth * biBitCount) + 31) & ~31) >> 3);     ← 单位：字节
biSizeImage = abs(biHeight) * stride;
```

拆开理解这个位运算：

| 步骤 | 含义 |
|---|---|
| `biWidth * biBitCount` | 一行有多少**位** |
| `+ 31` 再 `& ~31` | **向上取整到 32 位的整数倍** = 4 字节的整数倍（DWORD） |
| `>> 3` | 位 → 字节 |

**算给读者看**（24 位，每像素 3 字节）：

| 宽度 | 每行有效像素字节 | `stride` | **每行填充字节** | 480 行累计填充 |
|---|---|---|---|---|
| **640** | 1920 | **1920** | **0** ✅ | 0 |
| 641 | 1923 | 1924 | **1** ❌ | 480 |
| 642 | 1926 | 1928 | **2** ❌ | 960 |
| 643 | 1929 | 1932 | **3** ❌ | 1440 |
| **644** | 1932 | **1932** | **0** ✅ | 0 |

> **所以"宽度必须是 4 的倍数"不是经验之谈，是 stride 公式的直接推论**：每行字节数 = `宽 × 3`，必须能被 4 整除；因为 3 与 4 互质，所以**等价于"宽必须是 4 的倍数"**。
>
> `bmp_read.v` **完全不处理这些填充字节**（它只按 `像素数据总长 = 宽 × 高 × 3` 连续取），所以宽度不是 4 的倍数时，每行就会**错位累积**，图像表现为**斜切**。这也是为什么 640 是安全的。

### 4.2 ⭐ `biHeight` 的符号规则（官方原文）

> "对于未压缩的 RGB 位图，**如果 `biHeight` 为正值，则位图为自下而上的 DIB，原点位于左下角。如果 `biHeight` 为负数，则位图为自上而下 DIB，原点位于左上角。**"

| `biHeight` | 行序 | 文件里第 0 行的位置 |
|---|---|---|
| **正数（+480）** | **自下而上** bottom-up | 图像的**最下面**一行 |
| 负数（−480） | 自上而下 top-down | 图像的**最上面**一行 |

**本工程全部素材都是 `+480`**（实测 11 张，见第七节）。这正是第6站 `WRITE_V_FLIP = 1` 存在的原因。

---

## 五、★ 逐字节对照：官方字段 ↔ `bmp_read.v` 的解析

`bmp_read.v` 用一个 `rd_cnt`（从文件开头算起的字节序号）做 `case`，只挑它需要的字段：

| `rd_cnt` | 官方字段 | 代码里存到哪 | 拿来干什么 |
|---|---|---|---|
| 0, 1 | `bfType` | `header_0`, `header_1` | `header_match`：必须分别是 `"B"`、`"M"` |
| 2~5 | `bfSize` | `file_len[31:0]` | ① `file_sector_count = (file_len+511)>>9` 算文件占几个扇区；② `bmp_data_valid` 的右边界（读到文件尾就停） |
| **10~13** | **`bfOffBits`** | `pixel_offset[31:0]` | `bmp_data_valid` 的**左边界**：跳过头部/调色板，只把像素当数据 |
| **18~21** | **`biWidth`** | `width[31:0]` | `header_match`：`width[15:0] == bmp_width`（=640） |
| **22~25** | **`biHeight`** | `height[31:0]` | `header_match`：`height[15:0] == bmp_height`（=480） |
| **28~29** | **`biBitCount`** | `bit_count[15:0]` | `header_match`：必须 `== 24` |
| **30~33** | **`biCompression`** | `compression[31:0]` | `header_match`：必须 `== 0`（BI_RGB） |
| 其余 | — | `default: ;` | **全部忽略** |

### 5.1 被忽略的字段，以及"忽略掉会不会出事"

| 未读的官方字段 | 忽略的后果 |
|---|---|
| `biSize`（偏移 14） | ⚠️ **不校验信息头版本**。所以 `BITMAPV4HEADER`(108B) / `BITMAPV5HEADER`(124B) 也能通过 `header_match` —— 但**不会出错**，因为代码是用 `bfOffBits`（偏移 10）跳过整个头部的，不假设"头部固定 54 字节"。**这反而说明写得比看上去更健壮。** |
| `biPlanes`（26） | 规范要求必须为 1；不校验，实际影响可忽略 |
| `biSizeImage`（34） | 不校验。它本可由 `abs(h)×stride` 算出，属于冗余字段 |
| `biXPelsPerMeter`/`biYPelsPerMeter`（38/42） | 与显示无关（分辨率由 FPGA 的显示时序决定） |
| `biClrUsed`/`biClrImportant`（46/50） | 24 位无调色板，用不到 |

> ✅ **结论：`bmp_read` 的字段挑选是合理的** —— 它读了"判断这是不是我要的图"（4 个字段）+ "数据从哪开始到哪结束"（2 个字段）所必需的**最小集合**，其余交给 `bfOffBits` 这个间接层兜住了。

### 5.2 像素数据的解析（24 位）

BMP 24 位每个像素存 **3 个字节，顺序是 B、G、R**（蓝在前，与直觉相反）。`bmp_read.v` 的拼装：

| `bmp_byte_idx` | 第几个字节 | 官方含义 | 代码动作 |
|---|---|---|---|
| 0 | 第 1 字节 | **B**（蓝） | `bmp_data[7:0] <= 字节` |
| 1 | 第 2 字节 | **G**（绿） | `bmp_data[15:8] <= 字节` |
| 2 | 第 3 字节 | **R**（红） | `bmp_data[23:16] <= 字节`，同时 `bmp_data_wr_en <= 1`（这个像素好了） |

所以拼出来的 `bmp_data[23:0]` 实际是 **`{R, G, B}`**（R 在高字节）。

顶层再打包成 32 位：`{R, G, B, 8'b0}`，显示侧取 `[31:8]` —— 这一段闭环见第4站文档。

---

## 六、真实文件核对（实测）

拿厂商的 `doc/convert/output_bmp/1.bmp` 逐字段验证（文件实际长度 **921654** 字节）：

| 检查项 | 结果 |
|---|---|
| `bfType` = `0x4D42`（'BM'） | ✅ |
| `bfReserved1` / `bfReserved2` 都为 0 | ✅ |
| `bfOffBits` = 54 | ✅ |
| `biSize` = 40 / `biPlanes` = 1 | ✅ |
| `biWidth` × `biHeight` = 640 × **+480** | ✅（bottom-up） |
| `biBitCount` = 24 / `biCompression` = 0 | ✅ |
| `stride` 公式算得 1920，**每行填充 0 字节** | ✅ |
| `bfSize` == 54 + `abs(480) × 1920` = 54 + 921600 = **921654** | ✅ |
| 文件实际长度 == `bfSize` | ✅ |
| `biSizeImage` == `abs(biHeight) × stride` = 921600 | ✅ |

**全部对上** —— 说明厂商脚本产出的 BMP 完全合规。

---

## 七、三个坑（按"被踩到的概率"排序）

| # | 坑 | 症状 | 依据 |
|---|---|---|---|
| 1 | **`biHeight` 是负数（top-down）** | **这张图根本扫不到**（不是显示反了！）—— 因为 `height[15:0]` 会变成 `0xFE20`=65056 ≠ 480 | 第四节 4.2 + 第4站 `header_match` |
| 2 | **宽度不是 4 的倍数** | 每行错位累积 → 图像**斜切** | 第四节 4.1 的 stride 公式 |
| 3 | **把 PNG/JPG 改后缀为 `.bmp`** | 头部不是 `BM` → 扫描直接跳过 | 官方 `bfType` 定义 |

补充：**分辨率必须精确等于 640×480**（`header_match` 是精确比较，不是"缩放适配"）。所以四张素材的尺寸必须**完全统一**。

---

## 八、参考资料

| # | 资料 | 链接 |
|---|---|---|
| [1] | `BITMAPFILEHEADER` 结构（微软官方） | https://learn.microsoft.com/zh-cn/windows/win32/api/wingdi/ns-wingdi-bitmapfileheader |
| [2] | `BITMAPINFOHEADER` 结构（微软官方，含 stride 公式与 `biHeight` 符号规则） | https://learn.microsoft.com/zh-cn/windows/win32/api/wingdi/ns-wingdi-bitmapinfoheader |
| [3] | 位图存储 Bitmap Storage（微软官方，含真实十六进制 dump） | https://learn.microsoft.com/zh-cn/windows/win32/gdi/bitmap-storage |
| [4] | 位图头类型（`BITMAPV4HEADER` / `BITMAPV5HEADER`） | https://learn.microsoft.com/zh-cn/windows/win32/gdi/bitmap-header-types |
| [5] | Top-Down 与 Bottom-Up DIB（微软官方） | https://learn.microsoft.com/zh-cn/windows/win32/directshow/top-down-vs--bottom-up-dibs |
| [6] | 本地：`03_技术方案/素材规范与烧卡流程.md` | 素材检查清单 + 厂商转换/烧卡脚本说明 |
| [7] | 本仓库 `project/vendor/SD/bmp_read.v` | BMP 解析状态机与数据通路（逐块注释见源码） |
| [8] | 本仓库 `project/vendor/SD/frame_fifo_write.v` | 行序翻转（`WRITE_V_FLIP`）的实现与推导 |

> 📌 **建议**：把上面 [1][2][3] 三篇用浏览器**存成 PDF** 放到本目录，以后离线可查（本环境的 `web_fetch` 抓 learn.microsoft.com 是通的，但内容很长、留链接更快）。
