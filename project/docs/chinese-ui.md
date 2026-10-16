# 中文提示与四页教程

本版基于 PR #3 的提交 `0f6d027f25d792bd20665398652d17916af5ef7c`，适用 HX4S20C / EG4S20BG256、640×480 输出。队员的缩放和 SDRAM 缓存新版尚未提供，本目录保留已验证基线的接口，供后续合并。

## 中文显示

`top` 和 `top_adc` 默认 `UI_LANGUAGE_ZH=1`。设为 0 可恢复英文。独立使用 `cpr_overlay` 时，组件参数 `CHINESE_UI` 默认为 0；顶层显式选择中文，已有英文组件用户可继续使用原接口。

- 页眉显示教学浏览、自动展播、按压训练，以及亮度、对比度、页码和读卡状态。
- `训2/4` 表示训练教程目标；`页2/4` 表示浏览页。加载时页码对应排队目标，成功后对应已显示页，含义沿用原 12 位完整状态字。`加载中`、`缺教程`、`读卡错`、`已显示`、`未显示` 各有独立提示。
- 训练区显示次数、频率、档位、按压间隔、中断时间、轮换剩余、继续按压、轮换、故障与节拍提示。无有效 BPM 时显示 `---` 和“待测”。
- ADC 顶层显示“压力档位”和“未标定”；接触/按键演示显示“触点档位”和“演示输入”。档位与颜色保持原数字逻辑，不把 ADC 码值写成实际厘米。
- 底部按模式显示中文滚动字幕。自动展播暂停时，字幕位置和分帧计数一起冻结；每三个运行帧移动一个像素，周期 576 像素。全宽字幕窗口有 608 像素，因此可同时看到下一周期的开头。

字库为 Noto Sans CJK SC 的 130 个项目字符，16×16 单色点阵共 4160 字节；另有 43 条消息。ASCII 数字和中文共用本地字符 ID，ID 不是 UTF-8 或 GB2312。`cpr_font16_rom.v` 和 `cpr_zh_strings.v` 均包含初始化内容，不依赖工作目录下的运行时字体文件。字体许可见 `assets/font/OFL.txt`。

## 时钟、帧与接口

`cpr_text_zh.v` 接收原 `cpr_overlay` 已锁存的帧状态、BCD 数字和坐标。仅字幕偏移计数器为时序逻辑；字形、颜色和 RGB 选择均为组合逻辑，无新增像素寄存器或同步信号延迟。VS 下降沿仍锁存全帧状态。字幕只在 x16～367（训练）或 x16～623（教学/展播）、y448～463 内绘制。

中文实现继续使用页状态字的全部 12 位，包括独立的训练页标志。`build.tcl` 的源/目标各 12 位寄存器检查和 40 ns 总线保持约束保留。没有修改引脚、PLL、SDRAM/FIFO IP 或 CDC 例外。

与队员新版合并时，保留其缓存/缩放实现；加入三个中文 RTL 文件及工程登记，合并 `cpr_overlay` 的中文参数和末级文字遮罩选择，再传递两个顶层的 `UI_LANGUAGE_ZH`。不要用本目录的完整顶层直接覆盖队员已修改的顶层。若缩放流水线改变视频延迟，应在其最终输出端统一对齐 RGB、DE、VS 与 OSD 坐标，再执行本版画面自检和完整 TD 检查。

## 四页素材

`assets/content.zh-CN.json` 保存全部文案、页序及来源。`assets/tutorials/` 包含：

| 目录或文件 | 用途 |
|---|---|
| `masters/*.svg` | 自绘矢量源，原生画布 352×400，方便队员的缩放器使用 |
| `masters/*.png` | 1056×1200 高清渲染，可重新排版 |
| `bmp_training_safe/*.bmp` | 当前工程默认素材；640×480、24 位、无压缩、正高度，完整内容放在 x16～367、y32～431 |
| `bmp_viewer/*.bmp` | 以完整画面居中浏览的另一组素材；不应直接用于现有右侧反馈面板布局 |
| `cpr-tutorials-training-safe.img` | 四张默认 BMP 按 512 字节对齐打包的普通文件；生成它不会访问或写入 TF 卡 |
| `manifest.json` | BMP 和镜像哈希、扇区位置、来源链接 |
| `four-cards-preview.png` | 四页并排预览 |

顺序固定为判断与呼救、胸外按压、气道与人工呼吸、使用 AED。默认镜像起始扇区依次为 0、1801、3602、5403；胸外按压为零起始索引 1，与 `TRAINING_PAGE_INDEX=1` 一致。

编辑 SVG 时建议使用 Noto Sans CJK SC，以保持文字布局；PNG、BMP 和 FPGA 点阵已经包含像素，不依赖电脑安装字体。

当前工程按物理扇区扫描，直接把 BMP 当文件复制进 FAT 分区不能保证正确布局。镜像仅作为待写入的资源文件交付，本次没有写卡。队员若改为任意分辨率输入，可使用矢量源或高清 PNG 经其素材流程转换；`bmp_training_safe` 已经排版，避免再对它整体缩小一次。

## 文案依据

本套面向成人 CPR 培训，自绘图形没有复制 AHA/RCUK 的教材插画。判断、按压、回弹、轮换和通气流程参考 [AHA 2025 成人基本生命支持](https://cpr.heart.org/en/resuscitation-science/cpr-and-ecc-guidelines/adult-basic-life-support)；受训者与仅按压两种路径参见 [AHA CPR 说明](https://cpr.heart.org/en/resources/what-is-cpr)。AED 使用流程参考 [RCUK 2025 成人 BLS](https://www.resus.org.uk/professional-library/2025-resuscitation-guidelines/adult-basic-life-support-guidelines)。中国 120 急救号码依据[国家卫生健康委资料](https://www.nhc.gov.cn/wjw/tia/202101/5f75d1537d45467dbbecdcdd33411283.shtml)。核对日期为 2026-10-16。

第三页明确区分受训且愿意通气者的 30:2 和未受训/不能通气者的持续按压，不沿用旧方案中容易与有脉搏呼吸停止场景混淆的通气频次。AED 页由设备判断是否电击，不要求用户自行设置能量。素材用于成人培训示意，实操应结合规范培训和设备提示。

## 重建与验证

字体文件从 [Noto CJK 官方仓库](https://github.com/notofonts/noto-cjk/tree/main/Sans) 获取。已用字体 SHA-256 为 `2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b`。完整 OTF 不随工程分发；已生成的点阵 RTL 可直接构建。需要改文案时，在仓库根目录运行：

```text
python project/tools/generate_chinese_font.py --font /path/to/NotoSansCJKsc-Regular.otf
python project/tools/build_tutorial_assets.py --font /path/to/NotoSansCJKsc-Regular.otf --output /path/to/new-tutorial-directory
python project/tools/validate_tutorial_assets.py /path/to/new-tutorial-directory
python tests/sim/run.py --all --self-test-runner
```

修改字符集合或消息数量后，应同步核对字库测试的表大小；屏幕参考文件是独立的固定文案布局，不能用待测 RTL 输出替代。教程生成器拒绝覆盖现有输出目录。

`tb_chinese_rom` 检查全部字符行、未知 ID 和消息边界；`tb_chinese_scroll` 检查字幕分帧移动、暂停、模式、边界、周期空隙及复位；`tb_chinese_overlay` 用独立文案/点阵表逐像素检查四种状态下的按键及 ADC 两种画面，含中途改变输入、显示饱和、无效 BPM、错误/缺页/加载、DE 空白和教程区原像素。最新执行结果见 `chinese-validation-20261016.json`；旧文档中的构建数字不代表本次版本。
