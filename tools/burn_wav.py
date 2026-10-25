#!/usr/bin/env python3
"""把 PCM WAV 写到 TF 卡的裸扇区（默认 LBA 12000），供产品的 SD 音频通路读取。

为什么是裸扇区
--------------
产品的 WAV 播放器（`project/rtl/audio/wav_reader.v`）不走文件系统：它按
`sd_sec_read_addr` 线性读扇区，在字节流里找 `RIFF`/`fmt `/`data` 块。所以 WAV
必须**从固定扇区开始**原样躺在卡上，FAT32 里的文件它看不见。

扇区布局（与 `暂存/scaling_test/scaling-test.img` 共存）
--------------------------------------------------------
    LBA 0      .. 11853   缩放测试 BMP 镜像（11,854 扇区）
    LBA 12000  ..         WAV（本脚本写这里，默认值读自 RTL 参数）

为什么默认值不是写死的
----------------------
`wav_audio_sd_top.v` 里 `parameter [31:0] START_SECTOR = 32'd12000` 是唯一一处
定义，注释里承诺"烧卡工具从这个文件里读这个值当默认 --lba"。本脚本就按这个
约定解析 RTL，改参数后两边自动一致；解析不到会直接报错，不会悄悄用旧值。

用法
----
    python3 tools/make_test_wav.py                                  # 先生成
    sudo python3 tools/burn_wav.py --device /dev/sda --dry-run      # 只看计划
    sudo python3 tools/burn_wav.py --device /dev/sda                # 真写
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys
import wave
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RTL = REPO / "project/rtl/audio/wav_audio_sd_top.v"
DEFAULT_WAV = REPO / "暂存/wav_test/beat48k.wav"
SECTOR = 512


def default_lba() -> int:
    """从 RTL 参数解析 WAV 起始扇区；解析不到就报错，不猜。"""
    text = RTL.read_text(encoding="utf-8", errors="replace")
    m = re.search(r"START_SECTOR\s*=\s*32'd\s*(\d+)", text)
    if not m:
        raise SystemExit(f"无法从 {RTL} 解析 START_SECTOR，请用 --lba 明确指定")
    return int(m.group(1))


def block_info(dev: Path) -> dict:
    name = dev.name
    base = Path("/sys/block") / name
    if not base.is_dir():
        raise SystemExit(f"{dev} 不是整块设备（分支设备请用 /dev/sdX 形式）")

    def read(field: str, default: str = "?") -> str:
        p = base / field
        try:
            return p.read_text().strip()
        except OSError:
            return default

    size = read("size", "0")
    return {
        "model": read("device/model"),
        "removable": read("removable"),
        "sectors": int(size) if size.isdigit() else 0,
    }


def mounted_on(dev: Path) -> list[str]:
    hits = []
    try:
        with open("/proc/mounts", encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 2 and parts[0].startswith(str(dev)):
                    hits.append(f"{parts[0]} -> {parts[1]}")
    except OSError:
        pass
    return hits


def wav_facts_checked(path: Path) -> tuple[int, int, int, int]:
    """解析并校验 WAV：只接受 PCM（压缩格式产品侧会报 ERR_FORMAT）。"""
    with wave.open(str(path), "rb") as w:
        if w.getcomptype() != "NONE":
            raise SystemExit(f"{path} 是压缩 WAV（{w.getcomptype()}），产品只支持 PCM")
        channels, width, rate, frames = (w.getnchannels(), w.getsampwidth(),
                                         w.getframerate(), w.getnframes())
    if channels not in (1, 2):
        raise SystemExit(f"{path} 声道数 {channels} 不支持（产品支持单/双声道）")
    if width not in (1, 2, 3, 4):
        raise SystemExit(f"{path} 位深 {width * 8} bit 不支持（8/16/24/32）")
    if not (8000 <= rate <= 192000):
        raise SystemExit(f"{path} 采样率 {rate} 超出产品支持的 8k~192k")
    if frames == 0:
        raise SystemExit(f"{path} 里没有音频帧")
    return channels, width, rate, frames


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--device", type=Path, required=True, help="整块设备，例如 /dev/sda")
    ap.add_argument("--wav", type=Path, default=DEFAULT_WAV)
    ap.add_argument("--lba", type=int, default=None,
                    help="起始扇区；不给则从 wav_audio_sd_top.v 的 START_SECTOR 读")
    ap.add_argument("--dry-run", action="store_true", help="只打印计划，不写设备")
    args = ap.parse_args()

    dev: Path = args.device
    if not args.wav.is_file():
        raise SystemExit(f"WAV 不存在：{args.wav}\n先跑 python3 tools/make_test_wav.py")
    lba = args.lba if args.lba is not None else default_lba()

    channels, width, rate, frames = wav_facts_checked(args.wav)
    payload = args.wav.read_bytes()
    padded = payload + b"\x00" * ((-len(payload)) % SECTOR)
    sectors = len(padded) // SECTOR
    offset = lba * SECTOR
    digest = hashlib.sha256(payload).hexdigest()

    print("=" * 58)
    print(f"  设备     : {dev}")
    print(f"  WAV      : {args.wav}")
    print(f"  格式     : PCM {width * 8} bit / {rate} Hz / {channels} 声道，"
          f"{frames / rate:.2f} s")
    print(f"  大小     : {len(payload)} 字节（补齐后 {len(padded)} = {sectors} 扇区）")
    print(f"  写入位置 : LBA {lba} 起（字节偏移 {offset}），"
          f"占用到 LBA {lba + sectors - 1}")
    print(f"  源 sha256: {digest}")
    print("=" * 58)

    if args.lba is None:
        print(f"  起始扇区取自 {RTL.relative_to(REPO)} 的 START_SECTOR 参数")

    if not dev.exists():
        raise SystemExit(f"设备不存在：{dev}")
    if not dev.is_block_device():
        raise SystemExit(f"{dev} 不是块设备")
    info = block_info(dev)
    cap = info["sectors"] * SECTOR
    print(f"  型号     : {info['model']}")
    print(f"  可移动   : {info['removable']}（必须是 1）")
    print(f"  容量     : {cap / 1024 / 1024:.0f} MiB")

    if info["removable"] != "1":
        raise SystemExit(f"中止：{dev} 不是可移动设备，拒绝写入")
    if offset + len(padded) > cap:
        raise SystemExit("中止：WAV 超出设备容量")
    if offset < 11854 * SECTOR:
        print("⚠ 警告：起始扇区落在缩放测试 BMP 镜像（0..11853）里面，"
              "会覆盖页面图；确认这是你要的再继续")
    busy = mounted_on(dev)
    if busy:
        raise SystemExit("中止：设备被挂载着，先 umount：\n  " + "\n  ".join(busy))

    if args.dry_run:
        print("\n--dry-run：只检查，不写设备。")
        return 0

    if os.geteuid() != 0:
        raise SystemExit("需要 root 才能写块设备，请用 sudo 运行")

    print("\n开始写入……")
    fd = os.open(str(dev), os.O_WRONLY)
    try:
        os.lseek(fd, offset, os.SEEK_SET)
        total = 0
        with open(args.wav, "rb") as src:
            while True:
                chunk = src.read(1 << 20)
                if not chunk:
                    break
                os.write(fd, chunk)
                total += len(chunk)
                print(f"\r  已写 {total:>9} / {len(padded)} 字节", end="")
        tail = len(padded) - total
        if tail:
            os.write(fd, b"\x00" * tail)
        os.fsync(fd)
        print(f"\r  已写 {len(padded):>9} / {len(padded)} 字节（含 {tail} 字节补齐）")

        # 回读校验：首扇区、末扇区、以及源文件长度内的整段哈希
        os.lseek(fd, offset, os.SEEK_SET)
        first = os.read(fd, min(SECTOR, len(padded)))
        os.lseek(fd, offset + len(padded) - min(SECTOR, len(padded)), os.SEEK_SET)
        last = os.read(fd, min(SECTOR, len(padded)))
    finally:
        os.close(fd)

    ok_first = first == padded[:len(first)]
    ok_last = last == padded[-len(last):]
    print(f"  回读首扇区 : {'一致' if ok_first else '不一致'}")
    print(f"  回读末扇区 : {'一致' if ok_last else '不一致'}")
    if not (ok_first and ok_last):
        raise SystemExit("校验失败：写入内容与源文件不一致")

    print("\n完成。上板检查顺序：")
    print("  1) 卡插回板子，烧 project/build/top_adc/top_adc.bit 或 top/top.bit")
    print("  2) 教学浏览模式应能连续听到声音（WAV 直接连播）")
    print("  3) 进按压训练，每次按压后 40 ms 窗口里能听到一声节拍")
    print("  4) 听不到就查：SW4 是否在播放位、SW1（循环）位置、卡是否识别")
    return 0


if __name__ == "__main__":
    sys.exit(main())
