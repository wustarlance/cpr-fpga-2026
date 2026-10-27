# 移除0%对比度与训练心跳增强

本次基于2026-10-27再次从GitHub核对的 `main`：`33f7141ead898c853ef354f3748c69e69b23e4bd`。采用该版顶层、百分比字形、逐页语音、自动展播背景曲和训练专用心跳通路。

## 功能

对比度由K6循环 `100%→125%→150%→50%→75%→100%`，复位仍为100%。只跳过0%可选项，其余五档增益及百分比显示沿用主分支。底层通用换算／RGB模块仍能表示保留码0，正常控制器不会选到该码。

训练音源是 `audio/heartbeat_synth.v` 的片内合成心跳。第一声已接近Q15满幅，此次使用 `min(2×当前包络, 当前声部原峰值)` 提升衰减段，再与正弦相乘，避免直接放大PCM造成削顶或符号溢出。保留150/190 Hz音调、110 BPM、25/35 ms时长、70 ms起点间隔、100%/65%强弱比例、静音间隔和退出收尾。`BOOST_DECAY=0` 可编译回原包络，默认1开启增强。

两拍共52364帧的仿真对照，平方和由20551623010025472增至38342276585226240，同时间窗RMS电平约+2.71 dB；峰值不超过8388352（32767左移8位）。这是数字波形结果，实际听感需上板确认。教学语音和展播音乐的增益沿用主分支。

## 配套时序处理

初始两项功能修改在本机TD中触发了背景加载链的setup违例。按实际路径分级，没有改变时钟或增加setup豁免：

- `bmp_blur_background.v` 在CLEAR预计算裁剪右／上边界；接收像素时把范围及首行／首列标志与RGB并行保存，PIXEL_CHECK使用这些标志。
- 模糊处理先更新当前像素坐标，再通过内部BLUR_COORDS状态准备六个钳位邻点，避免“下个像素推进＋换行＋钳位”串联。每个缩略图像素、每遍模糊增加1拍，最大32×24×3共2304拍，100 MHz下约23.04 μs；done相应后移。
- `bmp_read_scaled.v` 在BYTE_FETCH与sector_q同拍保存 `row_byte<row_bytes`，BYTE_USE的像素有效、行缓存写入和通道推进共用该标志。两状态之间及USE背压期间行坐标不变，不增加字节周期，也不把padding当成RGB。
- `stride_m1` 在已有CHECK_END状态由已寄存的stride减一，拆开宽度乘法、对齐和减法；不增加头部检查周期。

`build.tcl` 还在映射后核对6个单比特video→SD控制首级、3位选曲首级及对应次级的数量，仅对这些已有同步器的首级增加 `set_false_path -hold`。所有setup、次级、RAM路径和相关PLL时钟关系继续检查。选曲码经两级同步后还须连续8个SD周期稳定才生效；首级setup继续限制飞行时间。没有新增整组时钟剪枝或SDRAM DQ多周期例外。

## 验证

15项当前输入哈希对应的功能自检通过：对比度控制、百分比换算、RGB对比度、心跳响度对照、原心跳波形契约、WAV逐页切换、WAV／波形联动、画面合成、原缩放像素参考、独立背景像素参考、缩放缓存流水、错误恢复、页面管理、模糊背景完整缓存链、选曲稳定过滤。

另6个故障副本分别恢复0%选项、禁用心跳增强、移除包络限幅、破坏裁剪判断、破坏右邻点、禁用字节有效标志，均被对应自检拒绝。缩放／背景参考覆盖padding、后置像素偏移、窄高／宽矮图、背压、取消及重试。工程输入审计77项，缺失文件及警告均为0。

TD版本为本机官方资料包中的6.2.168116，目标EG4S20BG256。演示顶层本轮完成布线和bitgen：setup +0.146 ns，hold +0.003 ns，输入及工具哈希前后一致；LUT 14697/19600，寄存器7553/19600，BRAM 46/64，PLL 3/4。

对应位流SHA256：`049144032efca00e2e324b382617345485784204bc083854c6e7d74fe5036c48`。2026-10-27 17:50（本地时间）已核对EG4S20BG256并成功临时下载到SRAM；操作者已确认教程底图正常、百分比显示正确且没有0%、训练心跳有声，并选择保留本版、不再增强。ADC顶层补充构建也完成布线和bitgen：setup +0.149 ns、hold +0.003 ns，未下载该ADC位流。

严格TD验收仍为failed：原有7条关键警告（PHY-7002×3、PHY-5079×1、USR-6135×3）没有消除，外部I/O及3项dangling节点也仍需复核。时序覆盖报告中没有缺失时钟、非法约束、组合环、FIFO约束失活或例外覆盖错误；这不等于外设时序或亚稳态MTBF已经物理签核。

## 复现与证据

从仓库根目录运行：

```powershell
D:/python/python.exe -X utf8 tests/sim/run.py tb_contrast_controls tb_heartbeat_loudness tb_heartbeat_synth tb_bmp_scaled tb_bmp_blur_fill
D:/python/python.exe -u -X utf8 project/verify_td.py --td E:/BaiduNetdiskDownload/HX4S20_Contest_202606/anlu/td/bin/td_commands_prompt.exe --stage full --tops top --timeout 1200
```

完整本机记录位于工作区 `outputs/contrast-heartbeat-main-20261027/`：`verification.json`、`final-functional-summary.json`、`mutants/frozen-summary.json`、`latest-main-top-build/` 及程序下载记录。TD构建记录为 `project/build/verify_20261027T094342.847160Z/`。

只执行临时SRAM功能测试，未写Flash或TF卡。此前旧基线尝试与旧恢复位流单独保留为对照，不能代表本次GitHub主分支的验证结果。
