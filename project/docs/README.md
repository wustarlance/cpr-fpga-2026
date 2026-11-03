# 设计文档索引

> 本目录共 50+ 篇，分两类：**先读**的是设计与契约文档（看实现怎么定的），**逐轮记录**是按日期的验证留痕（看每一步怎么验的）。
> 历史记录里的数字只代表当时版本，**当前状态以根 README「验证结论」一节为准**。

## 一、先读这些（按顺序，约 30 分钟）

| # | 文档 | 讲什么 |
|---|---|---|
| 1 | [image-cache-scaling.md](image-cache-scaling.md) | 四槽 SDRAM 全缓存 + 加载时等比缩放（翻页零读卡的根据） |
| 2 | [blur-background.md](blur-background.md) | 非 4:3 图的模糊补边：cover 裁切 → 32×24 面积平均 → 3 遍盒式模糊 → 双线性采样 |
| 3 | [frame-buffer-contract.md](frame-buffer-contract.md) | 帧发布契约：何时才算"这张图可以上屏" |
| 4 | [adc-contract.md](adc-contract.md) | 片内 ADC 数字契约：SOC/EOC 时序、稀疏采样、PD、通道与球脚 |
| 5 | [pressure-contract.md](pressure-contract.md) | 分压与归一化：码值 ↔ 电压 ↔ 压力档 |
| 6 | [training-pages.md](training-pages.md) · [training-layout.md](training-layout.md) | 训练页状态机、OSD 布局、计数与评级规则 |
| 7 | [audio-and-transitions.md](audio-and-transitions.md) | WAV 裸扇区选曲、心跳合成、自动轮播淡入淡出 |
| 8 | [sd-recovery.md](sd-recovery.md) | 读卡失败的重试/取消/回退契约 |
| 9 | [verification-report.md](verification-report.md) | 验证汇总：仿真项数、时序结论、板级确认边界 |

## 二、专题文档

| 主题 | 文档 |
|---|---|
| 中文界面与字库 | [chinese-ui.md](chinese-ui.md) |
| 心跳节拍器实现 | [heartbeat-synth-implementation.md](heartbeat-synth-implementation.md) |
| 时序与布局 | [io-timing-budget.md](io-timing-budget.md) · [timing-postsim-20261026.md](timing-postsim-20261026.md) · [timing-margin-20261028.md](timing-margin-20261028.md) · [clock-routing-20261028.md](clock-routing-20261028.md) · [sdram-forward-20261028.md](sdram-forward-20261028.md) |
| 开机音画顺序 | [startup-av-20261101.md](startup-av-20261101.md) |
| 来源与合规 | [source-provenance.md](source-provenance.md)（哪些是自研、哪些是厂商 HDL、哪些是 AI 辅助） |
| 与官方例程对比 | [official-reference-comparison-20261024.md](official-reference-comparison-20261024.md) |
| AI 辅助过程 | [deepseek-integration.md](deepseek-integration.md) · [deepseek-review-resolution.md](deepseek-review-resolution.md) |
| 接线图（图片） | [images/adc-wiring-only.png](images/adc-wiring-only.png)（纯接线）· [images/adc-wiring-j2.png](images/adc-wiring-j2.png)（带引脚表与实测值） |

## 三、逐轮验证记录（按日期，供追溯）

这些是每个改动轮次的留痕，文件名带日期；同名 `.json` 是当时的自检证据（构建哈希、时序数字、检查项）。

| 日期 | 记录 |
|---|---|
| 10-13 / 10-15 | [display-validation](display-validation-20261013.json) · [sd-validation](sd-validation-20261015.json) · [page-validation](page-validation-20261015.json) |
| 10-16 | [chinese-validation](chinese-validation-20261016.json) |
| 10-17 | [display-fixes-20261017.md](display-fixes-20261017.md) · [display-fix-validation](display-fix-validation-20261017.json) · [horizontal-lines-triage-20261017.md](horizontal-lines-triage-20261017.md) |
| 10-18 | [refresh-read-priority-20261018.md](refresh-read-priority-20261018.md) |
| 10-19 | [d107-and-write-path-20261019.md](d107-and-write-path-20261019.md) |
| 10-23 | [td-acceptance-20261023.md](td-acceptance-20261023.md) · [white-lines-20261023.md](white-lines-20261023.md) · [white-line-validation](white-line-validation-20261023.json) · [td-acceptance](td-acceptance-20261023.json) |
| 10-24 | [td-acceptance-followup-20261024.md](td-acceptance-followup-20261024.md) · [io-timing-verification](io-timing-verification-20261024.json) · [audio-and-transitions-verification](audio-and-transitions-verification-20261024.json) · [official-reference-comparison](official-reference-comparison-20261024.json) |
| 10-25 | [td-critical-audit-20261025.md](td-critical-audit-20261025.md) · [audio-and-transitions-verification](audio-and-transitions-verification-20261025.json) · [td-critical-audit](td-critical-audit-20261025.json) |
| 10-26 | [timing-postsim-20261026.md](timing-postsim-20261026.md) |
| 10-27 | [contrast-heartbeat-main-20261027.md](contrast-heartbeat-main-20261027.md) |
| 10-28 | [clock-routing-20261028.md](clock-routing-20261028.md) · [sdram-forward-20261028.md](sdram-forward-20261028.md) · [timing-margin-20261028.md](timing-margin-20261028.md) |
| 11-01 | [startup-av-20261101.md](startup-av-20261101.md) · [startup-av-verification](startup-av-verification-20261101.json) |

## 四、术语

| 词 | 含义 |
|---|---|
| 四槽 | SDRAM 里 4 块 640×480×24bit 帧缓存，分别对应 4 页教程 |
| contain | 等比缩放到能装下（不裁切），四周补边 |
| cover | 等比缩放到铺满（会裁切），用于模糊背景的源 |
| 峰值 | 一次按压中 `空载码值 − 当前码值` 的最大值，代表按压强度 |
| 目标带 | 峰值落在这一区间判"达标"，当前 1600~2400 |
