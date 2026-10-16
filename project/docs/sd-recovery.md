> 2026-10-15 后续更新：新增[训练页面管理](training-pages.md)。浏览模式失败仍清除原有相对翻页排队；训练模式明确排队的新绝对页号独立保留，恢复后处理最新请求。页眉显示 L/M/E，缺页时数码管为 D。下文记录首次 SD 恢复改动。

# SD 读取超时、取消与重试

2026-10-15。目标为 HX4S20C / EG4S20BG256；基于上游 `a9e1aadfded635304f6f06eebee021a11a8913a0`。本次只改主工程的 SD 读链及验证；官方 `05_lab_ex` 例程、引脚、PLL、SDRAM/FIFO IP 和时序约束保持原样。

## 用户看到的行为

图片读取失败时取消当前加载，释放 SD 总线，在相同的非显示缓冲区完整重试一次。两次尝试都失败后停止自动重试，已有画面继续显示，数码管的状态位显示 `E`。按下一张或上一张重新发起操作；若失败发生在开机扫描阶段，按键触发重新扫描。

失败时丢弃旧的排队翻页请求，自动重试保持同一图片；重试结束后再由新的按键请求决定下一次操作。

首次图片尚未成功时不会显示不完整图片，原有状态 OSD 继续工作。训练计数与模式逻辑不由 SD 读卡错误复位。

## 端口与时序契约

本次新增的传输、BMP、调度信号均属于 `sd_card_clk`，主工程为 100 MHz。请求按原有接口保持为电平，结束和错误事件为一个时钟宽的脉冲。

| 层 | 新信号 | 约定 |
|---|---|---|
| `sd_card_cmd` | `ready`、`block_read_error`、`spi_abort`、`read_cancel` | `ready` 表示命令层可接新请求；块读错误与 `block_read_req_ack` 同拍；取消/错误让 SPI 字节引擎退出在途字节 |
| `sd_card_sec_read_write` / `sd_card_top` | `sd_sec_ready`、`sd_sec_read_error`、`read_cancel` | 只有 ready 为高才接受新扇区请求；`sd_sec_read_end` 现在表示一次读取结束，成功和失败都会发出；接收方必须同拍检查 error |
| `bmp_read` | `cancel`、`abort_sd`、`operation_error`、`error_code` | 失败后撤销 SD/写帧请求、停止像素输出并回 idle；错误脉冲与原因码同拍。SD 正在恢复时不发新读请求 |
| `sd_card_bmp` | `media_error[2:0]` | 保存最近一次错误原因；重试耗尽时状态码为 E；成功发布或按键重新尝试会清除错误 |

`sd_sec_read_data_valid` 的字节会流式送入非显示缓冲区，但直到扇区 CRC、BMP 源完成、整帧写完成均确认后才允许发布。CRC 失败可能发生在已输出 512 字节之后，不能用“收到过像素”判断图片成功。

`media_error`：1 为 SD 命令/传输/CRC 错误；2 为加载文件头错误；3 为读取无进展、写入确认、整体加载超时或取消；4 为扇区结束时不足/超过 512 字节。顶层继续使用现有 `state_code` 数码管显示 E，详细原因保留在图片调度器的输出端口。

## 超时和重试参数

| `sd_card_bmp` 参数 | 默认值 | 100 MHz 下的含义 |
|---|---:|---|
| `TOKEN_TIMEOUT_CYCLES` | `CLK_FREQ_HZ / 10` | 100 ms 内未接受数据令牌，判错；最后一个允许时钟上收到合法令牌时成功优先 |
| `SPI_TIMEOUT_CYCLES` | `CLK_FREQ_HZ / 100` | 单字节请求 10 ms 内没有 ACK，终止该事务 |
| `READER_TIMEOUT_CYCLES` | `CLK_FREQ_HZ` | BMP 读/写确认阶段连续 1 s 无进展，取消；有效字节、扇区结束、写确认重置计数 |
| `LOAD_TIMEOUT_CYCLES` | `CLK_FREQ_HZ * 3` | 发布前一次图片尝试最多 3 s；避免错误长度、写完成缺失导致永久占用 |
| `RECOVERY_GUARD_CYCLES` | 32 | 取消后至少等待 32 个 SD 时钟，且解析器、SD 链均空闲，旧写 ACK 已撤销 |
| `RETRY_LIMIT` | 1 | 原始尝试之外最多再尝试一次；支持 0–254。非法值关闭自动重试，避免计数饱和后无限重试 |

时间参数为正整数时钟数。修改主频或 SPI 分频后必须重算预算，单字节超时应大于正常字节传输时间。以上是本工程选择的预算，不是对所有 SD 卡响应速度的保证。

## 取消与缓冲区归属

1. SD 层检测令牌超时、错误令牌、SPI 无 ACK 或 CRC 错误，结束失败事务。
2. BMP 层接收错误或发现扇区长度错误、无进展/取消，停止源输出，撤销请求。
3. 调度器锁住本次图片号与目标缓冲区，清除本次完成标志，等待传输恢复及旧写 ACK 消退。
4. 重试重新读取文件头并发出新的写帧请求。现有 `frame_fifo_write` 在新请求的 ACK 阶段清空 FIFO、重置地址与计数，所以旧半帧不能混入新帧。
5. 写 ACK 经两级同步进入 SD 域；只在本次写请求已被确认后接受写完成事件，防止取消前遗留的完成 toggle 冒充新帧完成。
6. 成功时继续沿用原来的双完成条件与帧边界发布握手，收到读端确认才释放旧显示缓冲区。

一旦 `publish_req` 已发出，不能单方面超时取消，因为读端可能已经采用新缓冲区。本次整体加载超时只作用于发布前；发布后仍等待原有 `publish_done`。内存/读帧时钟停摆导致的发布确认缺失，需要另行处理整机时钟故障，不能通过释放缓冲区绕过。

SPI 失败时拉高 CS，复位字节引擎，并在 CS 高期间完成一个 dummy 字节后重新接受命令。取消不复位整块 FPGA、训练核心、读帧通路或已经初始化的卡状态。

## 自检

仓库根目录执行：

```sh
python tests/sim/run.py tb_sd_cmd_recovery tb_sd_sector_recovery tb_sd_image_recovery tb_sd_retry_limits
python tests/sim/run.py --all --self-test-runner
```

| 自检 | 本次检查内容 |
|---|---|
| `tb_sd_cmd_recovery` | 令牌永久不返回、错误令牌、512 字节顺序、CRC 正确/错误、SPI 中途停顿、显式取消、令牌在截止拍到达、出错后再次成功读取 |
| `tb_sd_sector_recovery` | CMD17 错误不再无上限重复；块错误上传为扇区错误；取消、恢复期不接受新请求、出错后继续读取 |
| `tb_sd_image_recovery` | 真实 BMP 解析器＋调度器＋帧发布＋内存写状态机联动。覆盖一次失败后成功、持续失败、短扇区、半帧停顿、坏文件头、写 ACK 缺失、写完成缺失、扫描失败与手动恢复；检查全部像素和真实写地址 |
| `tb_sd_retry_limits` | 0 次重试、2 次重试和非法 255 配置；未完成首图不发布，重试结束后保持停止 |

图像故障自检用 4×2 像素图缩短运行时间，SD 字节/扇区和双时钟 FIFO、SDRAM 存储是行为模型；产品 BMP、调度器、帧发布、写帧状态机为实际 RTL。命令/扇区错误另用独立测试验证。测试不模拟真实卡的模拟信号或加密 FIFO 的物理时序。

CRC 期望表由 Python 标准库 `binascii.crc_hqx` 独立生成：512 字节为 `(13*i+7) & 255`，零初值 CRC 为 `0x56ed`。故意关闭令牌超时、放行坏 CRC、改写显示缓冲区、移除重试上限的四个变异都应被自检拒绝。

协议对照采用 SD Association 的 [Physical Layer Simplified Specification](https://www.sdcard.org/cms/wp-content/themes/sdcard-org/dl.php?f=Part1_Physical_Layer_Simplified_Specification_Ver5.10.pdf) 中 SPI 读数据令牌、错误令牌和块 CRC 约定。

## 本次边界

- 仍使用原始扇区扫描及连续 BMP 布局，没有实现 FAT32、音频调度或写卡恢复。
- 运行时读卡错误有有限重试；原有卡初始化循环和自动热插拔识别未在本次改造。卡掉电或重新插入后需要受控复位及实板验证。
- 没有烧写板卡、擦除 Flash 或写 TF 卡。工具构建与实板验收分开记录；本次构建明细见交付说明和验证索引。
