#!/usr/bin/env python3
"""生成一块"上板自检"用的 PCM WAV：48 kHz / 16 bit / 单声道，节拍器 + 提示音。

为什么需要它
------------
音频 PR 合入后，声音不再由片上音阶发生器产生，而是**从 TF 卡读 WAV**
（`project/rtl/audio/wav_audio_sd_top.v`，裸扇区、不认文件系统；一页一段，
首扇区由 `rtl/audio/wav_track_select.v` 的 `PICTURE_1..4` 参数给）。
没写 WAV 的卡插上去，
教学/展播没有声音、按压训练也没有节拍音，会被误判成"合并把音频弄坏了"。
这个脚本产出可以直接 `tools/burn_wav.py` 写卡的文件。

`--track 1..4` 会给每段换一个调（C / D / E / G 递增），这样翻页时"换没换曲"
一耳朵就能听出来 —— 四段都是一样的音的话，翻页换曲根本没法验。

内容设计（对着产品的两种播放方式）
--------------------------------
* 教学浏览 / 自动展播：`audio_gate` 常开 → WAV **连续播放**，当成背景音，
  所以这里放了能听出"一直在响"的旋律底噪。
* 按压训练：`audio_gate` 只在每次检测到按压后的 40 ms 窗口打开 → 只有节拍
  瞬态能听到，所以每拍都有明显点击声，110 BPM（与 `BEAT_MS = 545` 一致）。

用法
----
    python3 tools/make_test_wav.py --track 1            # 默认 30 s / 110 BPM
    python3 tools/make_test_wav.py --track 2 --seconds 20 --out 暂存/wav_test/track2.wav
"""
from __future__ import annotations

import argparse
import math
import random
import struct
import sys
import wave
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# 每个页一个调，按五度/三度递进，翻页时音高变化明显
TRACK_KEYS = {1: 1.000, 2: 1.122, 3: 1.260, 4: 1.498}   # C / D / E / G


def click(rate: int, amp: float, key: float = 1.0) -> list[float]:
    """40 ms 的衰减点击，能量集中在头 10 ms —— 对应训练模式那 40 ms 门。"""
    n = int(rate * 0.040)
    out = []
    for i in range(n):
        t = i / rate
        env = math.exp(-t / 0.006)
        # 1.6 kHz 主体 + 一点 3.2 kHz 泛音，小喇叭上更容易听出来
        out.append(amp * env * (math.sin(2 * math.pi * 1600 * key * t)
                                + 0.35 * math.sin(2 * math.pi * 3200 * key * t)))
    return out


def note(rate: int, freq: float, amp: float, seconds: float) -> list[float]:
    """软起软的提示音，用来在教学模式里听出"确实在播"。"""
    n = int(rate * seconds)
    out = []
    for i in range(n):
        t = i / rate
        env = math.exp(-t / 0.35) * (1.0 - math.exp(-t / 0.01))   # 起音不做爆音
        out.append(amp * env * math.sin(2 * math.pi * freq * t))
    return out


def build(rate: int, seconds: float, bpm: int, key: float = 1.0) -> list[float]:
    beat = 60.0 / bpm
    total = int(rate * seconds)
    buf = [0.0] * total
    # 大调五声音阶，每拍换一个音，循环（key 给每页开一个调）
    scale = [f * key for f in (523.25, 587.33, 659.25, 783.99, 880.00)]
    random.seed(2026)
    beats = int(seconds / beat)
    for b in range(beats):
        start = int(b * beat * rate)
        accent = (b % 4 == 0)
        # 节拍点击：强拍更响
        for i, v in enumerate(click(rate, 0.32 if accent else 0.20, key)):
            if start + i < total:
                buf[start + i] += v
        # 旋律底：每拍一个音，长度不到一拍，留出间隙
        f = scale[b % len(scale)]
        for i, v in enumerate(note(rate, f, 0.10, beat * 0.8)):
            if start + i < total:
                buf[start + i] += v
    # 峰值归一化到 -3 dBFS，避免削顶
    peak = max((abs(v) for v in buf), default=0.0)
    if peak > 0:
        g = (10 ** (-3 / 20)) / peak
        buf = [v * g for v in buf]
    return buf


def write_wav(path: Path, samples: list[float], rate: int, bits: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if bits == 16:
        scale, packer = 32767.0, "<h"
    elif bits == 24:
        scale, packer = 8388607.0, None       # 24 bit 手工打包
    else:
        raise SystemExit("只支持 16 或 24 bit")
    frames = bytearray()
    for v in samples:
        x = max(-1.0, min(1.0, v))
        if bits == 16:
            frames += struct.pack(packer, int(round(x * scale)))
        else:
            n = int(round(x * scale)) & 0xFFFFFF
            frames += bytes((n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF))
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(bits // 8)
        w.setframerate(rate)
        w.writeframes(bytes(frames))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=None,
                    help="输出路径；不给则用 暂存/wav_test/track<--track>.wav")
    ap.add_argument("--track", type=int, default=1, choices=(1, 2, 3, 4),
                    help="生成第几页的音频（1..4）：每页换一个调，方便听出翻页有没有换曲")
    ap.add_argument("--seconds", type=float, default=30.0)
    ap.add_argument("--bpm", type=int, default=110)
    ap.add_argument("--rate", type=int, default=48000)
    ap.add_argument("--bits", type=int, default=16, choices=(16, 24))
    args = ap.parse_args()

    if args.out is None:
        args.out = REPO / f"暂存/wav_test/track{args.track}.wav"

    # 采样率提醒：pcm_player 用 PLL 固定的 12.295082 MHz 侧时钟播，
    # 实际 48.027 kHz，所以文件做 48 kHz 最接近原速；别的采样率会整体快/慢一点。
    if args.rate != 48000:
        print(f"⚠ 采样率 {args.rate} 与板上的 48.027 kHz 不一致，播放会变速")

    key = TRACK_KEYS[args.track]
    samples = build(args.rate, args.seconds, args.bpm, key)
    write_wav(args.out, samples, args.rate, args.bits)

    size = args.out.stat().st_size
    sectors = (size + 511) // 512
    print(f"已生成 : {args.out}")
    print(f"格式   : PCM {args.bits} bit / {args.rate} Hz / 单声道，"
          f"{args.seconds:g} s，{args.bpm} BPM，第 {args.track} 页（key ×{key:.3f}）")
    print(f"大小   : {size} 字节 = {sectors} 扇区（约 {sectors / 2048:.2f} MiB）")
    print(f"长度   : 每页要留够 {sectors} 扇区，四段起点别重叠")
    print()
    print("下一步（需要 sudo，会写卡）：")
    print(f"  sudo python3 tools/burn_wav.py --device /dev/sda --track {args.track}"
          f" --wav {args.out}")
    print("  （不给 --lba 时，起始扇区取自 wav_track_select.v 的 "
          f"parameter PICTURE_{args.track}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
