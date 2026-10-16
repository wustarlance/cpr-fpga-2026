# 帧缓存发布与复位契约

`rtl/frame_buffer_publish.v` 在 SD 时钟域接受一拍 `publish` 和对应的 `buffer_index`。仅在 `busy=0` 接受请求；源域锁存缓冲区号，保持到读端确认返回。各域须共同异步置复位，再在各自时钟下释放。

请求 toggle 经两级同步进入 40 MHz 内存域。模块额外锁存稳定的编号，等 `vendor/SD/frame_fifo_read.v` 的 `frame_start` 才更改 `active_index`。`frame_start` 表示读 FSM 进入 `S_ACK`；下一拍读端锁存该编号的帧首地址。确认在这一拍才发出，经两级同步回到 SD 域，产生一拍 `done`。

主工程将 `READ_INDEX_SYNCHRONOUS=1`，直接使用内存域的 active 编号。默认参数为 0，保留旧独立调用者的编号同步行为。不能将一个 SD 域编号直接接入同步模式。

图片调度器的过程是：

1. 扫描并将前四张图片各加载到独立固定槽位，槽位在本次上电期间不覆写。
2. 分别锁存BMP缩放输出完成和SDRAM写完成；不假定两者先后顺序，同时成立才置cache_valid。
3. 首张有效槽立即发起发布；其他图片后台加载可以与发布并行。
4. 保持发布索引和publish_wait，收到done后才改变实际显示图号。只有cache_valid的槽可发起发布。
5. 已缓存图片切换只发布新索引，不重新加载；未缓存的翻页保留单个待处理请求。

源完成必须先观察 BMP 解析器离开空闲，再返回空闲；启动请求时遗留的一拍 `ready` 不能算完成。第一张图片也必须等待新帧读地址被捕获，不依靠复位后恰好读 buffer0 来提前确认。

`reset_publish.sdc` 为保持的数据总线设置 25 ns 上限，只豁免 request/ack 第一级同步寄存器。不能对整个内存/SD 时钟组 false-path。

复位释放模块接收原始共同复位原因 `rst_n && all_plls_locked`，失锁/按键立即清零；50 MHz 的上电等待 `por_ready` 经各域两级 readiness 同步，再经两级 release 寄存器放行。只有 readiness 首级接收异域电平，SDC 对 `por_ready → ready_meta` 设置局部例外，后续链仍分析时序。同步释放保证协议顺序，不代替实际 PLL、电源和亚稳态硬件验证。

测试入口：`tb_frame_buffer_publish` 检查真实读 FSM 的地址捕获、切换确认、复位取消；`tb_sd_buffer_ownership` 检查四槽缓存、连续翻页和完成先后顺序；`tb_sd_scaled_pipeline` 检查实际写地址/像素、FIFO回压及读优先仲裁；`tb_reset_release` 检查异步置位与延迟释放。读卡/写存储模型不能代表加密 SDRAM 的实板行为。
