# attic/audio-fade —— 已下线的"混音 + 2 ms 交叉淡化"实现

2026-10-25 第五次改：训练模式的心跳改成**纯二选一多路选择器**（`sel = 训练模式`，
选 WAV 或 `heartbeat_synth`），混音逻辑全部删除，这四个文件因此不再参与构建：

| 文件 | 原用途 |
|---|---|
| `audio_crossfade.v` | `out = A + (B−A)·α`，96 帧线性斜坡，用于进出训练时消咔哒 |
| `heart_mix_stage.v` | 两段斜坡串联：音乐先以斜坡进入心跳那一路，再整体交叉淡化 |
| `tb_audio_crossfade.v` | 淡化契约测试（96 帧、单调、无过冲、半途反向） |
| `tb_heart_mix_stage.v` | 合流契约测试（含"拨混音必须走斜坡不能阶跃"的反证） |

它们从 `project/project.al` 和 `tests/sim/run.py` 里都摘掉了，所以 TD 构建和仿真
回归都不会再编译它们（放在 `rtl/` 里会被误当源码，所以挪到 `attic/`）。

## 想恢复淡化的最小做法

只想要"不咔哒"、不要混音的话，把 `audio_crossfade.v` 放回 `project/rtl/audio/`，
在 `wav_audio_path.v` 的 §5.5 里把两行 mux 换成：

```verilog
audio_crossfade #(.MCLK_HZ(MCLK_HZ), .FADE_MS(2)) u_xfade (
    .I_clk(I_mclk), .I_rst(I_mclk_rst), .I_frame_stb(W_frame_stb),
    .I_sel(I_heart_en),
    .I_a_l(W_wav_l), .I_a_r(W_wav_r),
    .I_b_l(W_hb_l),  .I_b_r(W_hb_r),
    .O_l(W_out_l),   .O_r(W_out_r),  .O_mixing()
);
```

再把 `audio_crossfade.v` 加回 `project.al`、把 `tb_audio_crossfade` 加回 `run.py` 即可。
