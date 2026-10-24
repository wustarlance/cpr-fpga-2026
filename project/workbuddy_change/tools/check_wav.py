#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
check_wav.py -- 检查 WAV 文件是否适合本工程 HDMI 音频通路

用法：
    python check_wav.py song.wav
    python check_wav.py D:/某个目录/*.wav

为什么需要这个工具：
    本工程 HDMI 音频帧率固定 48 kHz（MCLK/256）。WAV 若是 44.1 kHz，
    pcm_player 做的是"最近邻"重采样（保持上一帧，不插值），实测 SNR
    只有约 27.7 dB，会听到明显的高频镜像噪声（像蜂鸣/嘶嘶声）。
    换成 48 kHz 素材则 1:1 直通，SNR 基本无损。

只用标准库，不需要 numpy。
"""
import sys
import wave
import os
import struct


def check(path):
    print("=" * 62)
    print(f"文件: {path}")
    size = os.path.getsize(path)
    print(f"大小: {size:,} 字节")

    try:
        with wave.open(path, "rb") as w:
            ch = w.getnchannels()
            width = w.getsampwidth()
            rate = w.getframerate()
            nframes = w.getnframes()
            comp = w.getcomptype()
    except Exception as e:
        # 可能是 WAVE_FORMAT_EXTENSIBLE / IEEE float，wave 模块读不了，退回手工解析
        print(f"[!] wave 模块无法打开: {e}")
        return manual(path)

    bits = width * 8
    dur = nframes / rate if rate else 0
    print(f"声道数  : {ch} ({'立体声' if ch == 2 else '单声道' if ch == 1 else '多声道'})")
    print(f"位深    : {bits} bit")
    print(f"采样率  : {rate} Hz")
    print(f"帧数    : {nframes:,}")
    print(f"时长    : {dur:.2f} 秒")
    print(f"压缩    : {comp}")

    verdict(rate, bits, ch)
    return rate


def manual(path):
    """手工解析 RIFF，能识别 WAVE_FORMAT_EXTENSIBLE 和 float32"""
    with open(path, "rb") as f:
        head = f.read(12)
        if head[:4] != b"RIFF" or head[8:12] != b"WAVE":
            print("[X] 不是 RIFF/WAVE 文件")
            return None
        rate = bits = ch = fmt_tag = None
        while True:
            ck = f.read(8)
            if len(ck) < 8:
                break
            cid = ck[:4]
            csz = struct.unpack("<I", ck[4:])[0]
            if cid == b"fmt ":
                body = f.read(csz)
                fmt_tag, ch, rate = struct.unpack("<HHI", body[:8])
                bits = struct.unpack("<H", body[14:16])[0]
                if fmt_tag == 0xFFFE and len(body) >= 26:
                    sub = struct.unpack("<H", body[24:26])[0]
                    print(f"[i] WAVE_FORMAT_EXTENSIBLE, 子格式 0x{sub:04X}")
                if csz % 2:
                    f.read(1)
            elif cid == b"data":
                print(f"data 块 : {csz:,} 字节")
                break
            else:
                f.seek(csz + (csz % 2), 1)

        tag_name = {1: "PCM", 3: "IEEE float", 0xFFFE: "EXTENSIBLE"}.get(fmt_tag, f"0x{fmt_tag:04X}")
        print(f"格式    : {tag_name}")
        print(f"声道数  : {ch}")
        print(f"位深    : {bits} bit")
        print(f"采样率  : {rate} Hz")
        for b in (8, 16, 24, 32):
            if bits == b:
                pass
        verdict(rate, bits, ch)
        return rate


def verdict(rate, bits, ch):
    print("-" * 62)
    ok = True
    if rate == 48000:
        print("[OK]  采样率 48 kHz -> 1:1 直通，无重采样噪声")
    elif rate == 44100:
        print("[!!]  采样率 44.1 kHz -> 走最近邻重采样，SNR 约 27.7 dB")
        print("      典型听感：音乐上叠一层高频镜像噪声（蜂鸣/嘶嘶）")
        print("      解决：优先换 48 kHz 素材；或把 pcm_player 改线性插值")
        ok = False
    elif rate is None:
        print("[X]   没能解析出采样率")
        ok = False
    else:
        print(f"[!!]  采样率 {rate} Hz 不是 48 kHz -> 会重采样，噪声明显")
        print("      建议先转成 48 kHz 再烧卡")
        ok = False

    if bits not in (16, 24, 32, 8):
        print(f"[!!]  位深 {bits} bit 不是常见值，reader 可能解析异常")
        ok = False
    elif bits == 8:
        print("[i]   8 bit PCM 在 reader 里会左移对齐到 24 bit，注意音量")
    elif bits == 32:
        print("[i]   32 bit 若为 IEEE float，本工程不支持（只认整数 PCM）")
    if ch not in (1, 2):
        print(f"[!!]  {ch} 声道，本工程按立体声交织解析，可能错位")
        ok = False

    print("-" * 62)
    print("结论: " + ("可以直接烧卡" if ok else "建议先处理格式问题"))
    return ok


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(1)
    import glob
    files = []
    for a in args:
        files.extend(sorted(glob.glob(a)) or [a])
    for p in files:
        try:
            check(p)
        except Exception as e:
            print(f"[X] {p}: {e}")
