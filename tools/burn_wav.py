#!/usr/bin/env python3
"""把 PCM WAV 写到 TF 卡的裸扇区（默认对齐 wav_track_select.v 的 PICTURE_x 参数），供产品的 SD 音频通路读取。

为什么是裸扇区
--------------
产品的 WAV 播放器（`project/rtl/audio/wav_reader.v`）不走文件系统：它按
`sd_sec_read_addr` 线性读扇区，在字节流里找 `RIFF`/`fmt `/`data` 块。所以 WAV
必须**从固定扇区开始**原样躺在卡上，FAT32 里的文件它看不见。

扇区布局（与 `暂存/scaling_test/scaling-test.img` 共存）
--------------------------------------------------------
    LBA 0      .. 11853   缩放测试 BMP 镜像（11,854 扇区）
    LBA 12000  ..         WAV：一页一段，四段从 PICTURE_1..4 各自开始
    LBA 500000 ..         WAV：第 5 段 FREE_SONG（自动轮播模式共用，2026-10-26 新增）

为什么默认值不是写死的
----------------------
`project/rtl/audio/wav_track_select.v` 的 module 参数默认值
`PICTURE_1 = 32'd12000 … FREE_SONG = 32'd500000` 是**全工程唯一一处**定义：
`wav_audio_sd_top` 例化它时不写覆盖，顶层也不写，所以 RTL 里只赋值一次。
本脚本按 `--track N` 解析出对应的 PICTURE_N 当默认 --lba，改 RTL 后两边自动
一致；解析不到会直接报错，不会悄悄用旧值。

两种写入模式
------------
* **段模式**（`--track 1..5` / `--free-song`）：起始扇区从 RTL 取，并且会检查
  "这段会不会盖住下一段的起点"，适合正常烧四页 + 第 5 段。
* **裸扇区模式**（`--sector N`，`--lba N` 是它的别名）：完全按你给的扇区写，
  **不读 RTL、不做段间越界检查**（只保留容量 / 可移动 / 未挂载三项安全闸）。
  需要自己保证 RTL 里有一段正好指向这个 LBA，否则板子读不到。

两个平台
--------
* Linux：`/dev/sdX` 整块设备，需要 root（`sudo`）。原有行为，未改。
* Windows：`\\\\.\\PhysicalDriveN`（N 用「磁盘管理」里的磁盘号），需要
  **管理员权限**；写入前会尝试锁卷 + 卸载卷（和 Win32DiskImager 同一套
  FSCTL），因此卡上原有文件系统的缓存会被丢掉。只接受**可移动介质**，
  内置硬盘一律拒绝。

用法
----
    # ---- Linux ----
    sudo python3 tools/burn_wav.py --device /dev/sda --track 1 --dry-run
    sudo python3 tools/burn_wav.py --device /dev/sda --track 1
    sudo python3 tools/burn_wav.py --device /dev/sda --free-song        # 写 LBA 500000
    sudo python3 tools/burn_wav.py --device /dev/sda --sector 500000 --wav my.wav

    # ---- Windows（管理员 cmd / PowerShell）----
    python tools\\burn_wav.py --list                              # 先看盘号（不用管理员）
    python tools\\burn_wav.py --device \\\\.\\PhysicalDrive2 --free-song --dry-run
    python tools\\burn_wav.py --device \\\\.\\PhysicalDrive2 --free-song --confirm

    # 懒人版：双击 tools\\烧音频到TF卡.bat（会自己提权、列盘、给 1..5 选段）
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
RTL_SEL = REPO / "project/rtl/audio/wav_track_select.v"
SECTOR = 512
IS_WIN = os.name == "nt"
# 段名与 wav_track_select.v 的参数名一一对应：--track 1..4 = 四页，5 = FREE_SONG
PICTURE_PARAMS = ("PICTURE_1", "PICTURE_2", "PICTURE_3", "PICTURE_4", "FREE_SONG")
BMP_IMAGE_END = 11853          # 缩放测试镜像占 LBA 0..11853
FREE_SONG_LBA = 500000         # RTL 解析失败时的兜底值，仅 --free-song 用


def picture_lbas() -> list[int]:
    """从 wav_track_select.v 的参数默认值解析五段音频的首扇区；不猜。"""
    text = RTL_SEL.read_text(encoding="utf-8", errors="replace")
    out = []
    for name in PICTURE_PARAMS:
        # 形如：parameter [31:0] PICTURE_1      = 32'd12000,
        m = re.search(rf"parameter\s*\[[^\]]*\]\s*{name}\s*=\s*32'd\s*(\d+)", text)
        if not m:
            raise SystemExit(
                f"无法从 {RTL_SEL} 解析 parameter {name} = 32'd…；"
                f"请用 --lba 明确指定")
        out.append(int(m.group(1)))
    return out


# ---------------------------------------------------------------------------
# 设备探测
# ---------------------------------------------------------------------------
def block_info_unix(dev: Path) -> dict:
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


def _win_err(msg: str) -> OSError:
    import ctypes
    return ctypes.WinError(ctypes.get_last_error()) if False else OSError(
        ctypes.get_last_error(), msg)


class _WinDisk:
    """Windows 物理盘的最小封装：探测 / 锁卷 / 定位写。只用 ctypes，不依赖 pywin32。"""

    GENERIC_READ = 0x80000000
    GENERIC_WRITE = 0x40000000
    FILE_SHARE_READ = 0x1
    FILE_SHARE_WRITE = 0x2
    OPEN_EXISTING = 3
    FILE_BEGIN = 0
    INVALID_HANDLE_VALUE = -1

    IOCTL_DISK_GET_DRIVE_GEOMETRY_EX = 0x000700A0
    IOCTL_STORAGE_QUERY_PROPERTY = 0x002D1400
    IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS = 0x00560000
    FSCTL_LOCK_VOLUME = 0x00090018
    FSCTL_DISMOUNT_VOLUME = 0x00090020

    def __init__(self, path: str):
        import ctypes
        from ctypes import wintypes
        self.ct = ctypes
        self.wt = wintypes
        self.k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        self.k32.CreateFileW.restype = wintypes.HANDLE
        self.k32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD,
                                         wintypes.DWORD, wintypes.LPVOID,
                                         wintypes.DWORD, wintypes.DWORD,
                                         wintypes.HANDLE]
        self.k32.DeviceIoControl.argtypes = [wintypes.HANDLE, wintypes.DWORD,
                                             wintypes.LPVOID, wintypes.DWORD,
                                             wintypes.LPVOID, wintypes.DWORD,
                                             ctypes.POINTER(wintypes.DWORD),
                                             wintypes.LPVOID]
        self.k32.CloseHandle.argtypes = [wintypes.HANDLE]
        self.k32.SetFilePointerEx.argtypes = [wintypes.HANDLE, ctypes.c_int64,
                                              ctypes.POINTER(ctypes.c_int64),
                                              wintypes.DWORD]
        self.k32.WriteFile.argtypes = [wintypes.HANDLE, wintypes.LPCVOID,
                                       wintypes.DWORD, ctypes.POINTER(wintypes.DWORD),
                                       wintypes.LPVOID]
        self.k32.ReadFile.argtypes = [wintypes.HANDLE, wintypes.LPVOID, wintypes.DWORD,
                                      ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID]
        self.path = path
        self.h = None

    def open(self, write: bool):
        access = self.GENERIC_READ | (self.GENERIC_WRITE if write else 0)
        h = self.k32.CreateFileW(self.path, access,
                                 self.FILE_SHARE_READ | self.FILE_SHARE_WRITE,
                                 None, self.OPEN_EXISTING, 0, None)
        if h == self.wt.HANDLE(self.INVALID_HANDLE_VALUE).value or h in (None, -1):
            raise SystemExit(f"打不开 {self.path}：{self.ct.WinError(self.ct.get_last_error())}"
                             f"\n（需要管理员权限；设备号也要对）")
        self.h = h
        return h

    def close(self):
        if self.h:
            self.k32.CloseHandle(self.h)
            self.h = None

    def _ioctl(self, code: int, inbuf, outsize: int):
        out = self.ct.create_string_buffer(outsize)
        ret = self.wt.DWORD(0)
        ok = self.k32.DeviceIoControl(self.h, code, inbuf, self.ct.sizeof(inbuf) if inbuf else 0,
                                      out, outsize, self.ct.byref(ret), None)
        if not ok:
            raise self.ct.WinError(self.ct.get_last_error())
        return out.raw[:ret.value]

    def geometry(self) -> dict:
        self.open(write=False)
        try:
            raw = self._ioctl(self.IOCTL_DISK_GET_DRIVE_GEOMETRY_EX, None, 256)
            sector_size = int.from_bytes(raw[20:24], "little")
            disk_size = int.from_bytes(raw[24:32], "little", signed=True)
            # STORAGE_DEVICE_DESCRIPTOR：RemovableMedia 在偏移 10，ProductId 偏移在 16
            q = self.ct.create_string_buffer(12)   # STORAGE_PROPERTY_QUERY, PropertyId=0
            desc = self._ioctl(self.IOCTL_STORAGE_QUERY_PROPERTY, q, 1024)
            removable = desc[10]
            pid_off = int.from_bytes(desc[16:20], "little")
            model = desc[pid_off:desc.find(b"\x00", pid_off)].decode("ascii", "replace") \
                if pid_off else "?"
        finally:
            self.close()
        return {
            "model": model.strip() or "?",
            "removable": "1" if removable else "0",
            "sectors": disk_size // (sector_size or SECTOR),
            "sector_size": sector_size or SECTOR,
        }

    def volumes_on_disk(self, disk_no: int) -> list[str]:
        """列出这块物理盘上的卷（\\\\.\\X:），用来锁卷/卸载卷。"""
        found = []
        for letter in "ABCDEFGHIJKLMNOPQRSTUVWXYZ":
            vp = f"\\\\.\\{letter}:"
            if not os.path.exists(vp):
                continue
            vh = self.k32.CreateFileW(vp, self.GENERIC_READ | self.GENERIC_WRITE,
                                      self.FILE_SHARE_READ | self.FILE_SHARE_WRITE,
                                      None, self.OPEN_EXISTING, 0, None)
            if vh in (None, -1):
                continue
            try:
                raw = self._ioctl_h(vh, self.IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS, 1024)
                if int.from_bytes(raw[8:12], "little") == disk_no:
                    found.append(vp)
            except OSError:
                pass
            finally:
                self.k32.CloseHandle(vh)
        return found

    def _ioctl_h(self, h, code: int, outsize: int):
        out = self.ct.create_string_buffer(outsize)
        ret = self.wt.DWORD(0)
        if not self.k32.DeviceIoControl(h, code, None, 0, out, outsize,
                                       self.ct.byref(ret), None):
            raise self.ct.WinError(self.ct.get_last_error())
        return out.raw[:ret.value]

    def lock_and_dismount(self, disk_no: int) -> list[str]:
        notes = []
        for vp in self.volumes_on_disk(disk_no):
            vh = self.k32.CreateFileW(vp, self.GENERIC_READ | self.GENERIC_WRITE,
                                      self.FILE_SHARE_READ | self.FILE_SHARE_WRITE,
                                      None, self.OPEN_EXISTING, 0, None)
            if vh in (None, -1):
                notes.append(f"{vp} 打不开（跳过锁卷）")
                continue
            for code, what in ((self.FSCTL_LOCK_VOLUME, "锁卷"),
                               (self.FSCTL_DISMOUNT_VOLUME, "卸载卷")):
                try:
                    self._ioctl_h(vh, code, 0)
                    notes.append(f"{vp} {what} 成功")
                except OSError as exc:
                    notes.append(f"{vp} {what} 失败：{exc}")
            # 句柄故意不关：卷在写入全程保持锁定
        return notes

    def seek_write(self, offset: int, data: bytes):
        cur = self.ct.c_int64(0)
        if not self.k32.SetFilePointerEx(self.h, offset, self.ct.byref(cur), self.FILE_BEGIN):
            raise self.ct.WinError(self.ct.get_last_error())
        chunk = 1 << 20
        for i in range(0, len(data), chunk):
            part = data[i:i + chunk]
            done = self.wt.DWORD(0)
            buf = self.ct.create_string_buffer(part, len(part))
            if not self.k32.WriteFile(self.h, buf, len(part), self.ct.byref(done), None):
                raise self.ct.WinError(self.ct.get_last_error())
            if done.value != len(part):
                raise OSError(f"短写：{done.value}/{len(part)} 字节")
        self.k32.FlushFileBuffers(self.h)

    def seek_read(self, offset: int, n: int) -> bytes:
        cur = self.ct.c_int64(0)
        if not self.k32.SetFilePointerEx(self.h, offset, self.ct.byref(cur), self.FILE_BEGIN):
            raise self.ct.WinError(self.ct.get_last_error())
        buf = self.ct.create_string_buffer(n)
        done = self.wt.DWORD(0)
        if not self.k32.ReadFile(self.h, buf, n, self.ct.byref(done), None):
            raise self.ct.WinError(self.ct.get_last_error())
        return buf.raw[:done.value]


def win_disk_number(dev: Path) -> int:
    m = re.fullmatch(r"\\\\.\\[Pp]hysical[Dd]rive(\d+)", str(dev))
    if not m:
        raise SystemExit(f"Windows 下 --device 必须写成 \\\\.\\PhysicalDriveN，收到：{dev}")
    return int(m.group(1))


def list_disks_win() -> None:
    """列出物理盘（只读、不用管理员）：靠 PowerShell 的 Get-Disk / Get-Partition。

    为什么不用自己开 \\\\.\\PhysicalDriveN 去问：读物理盘也要管理员，而"找盘号"
    这一步恰恰应该在提权之前做完，否则用户得先瞎猜一个盘号再提权。
    """
    import json
    import subprocess

    script = (
        "[Console]::OutputEncoding=[Text.Encoding]::UTF8;"
        "$rows=@();"
        "foreach($d in Get-Disk){"
        "  $l=(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue |"
        "      Where-Object {$_.DriveLetter} | ForEach-Object {$_.DriveLetter}) -join ',';"
        "  $rows += [pscustomobject]@{"
        "    n=$d.Number; model=$d.FriendlyName; size=$d.Size;"
        "    bus=[string]$d.BusType; letters=$l } };"
        "$rows | ConvertTo-Json -Compress"
    )
    try:
        r = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", script],
                           capture_output=True, timeout=40)
    except OSError as exc:
        raise SystemExit(f"调 PowerShell 失败：{exc}\n"
                         f"改用「磁盘管理」看盘号（diskmgmt.msc）。")
    txt = r.stdout.decode("utf-8", "replace").lstrip("\ufeff").strip()
    if not txt:
        raise SystemExit("PowerShell 没输出（Get-Disk 不可用）。\n"
                         "改用「磁盘管理」看盘号：Win+X → 磁盘管理，"
                         "列表左边那一列「磁盘 N」就是盘号。")
    try:
        rows = json.loads(txt)
    except json.JSONDecodeError:
        raise SystemExit(f"解析 PowerShell 输出失败，原始内容：\n{txt[:400]}")
    if isinstance(rows, dict):
        rows = [rows]

    print("Windows 物理盘（盘号 = 下面第一列）：")
    print(f"  {'盘号':<5}{'总线':<7}{'可移动':<7}{'容量':>9}  {'盘符':<8}型号")
    print("  " + "-" * 66)
    for row in rows:
        num = row.get("n")
        bus = (row.get("bus") or "?").upper()
        size = int(row.get("size") or 0)
        letters = row.get("letters") or "-"
        model = row.get("model") or "?"
        # BusType: USB / SD / MMC 才是读卡器；SATA/NVMe 是内置盘，脚本会拒绝
        removable = "是" if bus in ("USB", "SD", "MMC") else "否"
        flag = "  ← 读卡器" if removable == "是" else ""
        print(f"  {num:<5}{bus:<7}{removable:<7}{size / 1024 ** 3:>7.1f}G  {letters:<8}{model}{flag}")
    print()
    print("  认卡看「容量 + 型号」：读卡器通常是十几/几十 G、型号里带 SD/Reader。")
    print("  写错盘 = 那块盘上的数据全没。不确定就先 Win+X → 磁盘管理 对一遍。")


def list_disks_unix() -> None:
    import glob
    print("Linux 块设备（-d 参数用 /dev/xxx）：")
    for path in sorted(glob.glob("/sys/block/*")):
        name = os.path.basename(path)
        if name.startswith(("loop", "ram", "zram", "sr")):
            continue
        try:
            sectors = int(open(f"{path}/size", encoding="ascii").read().strip())
            removable = open(f"{path}/removable", encoding="ascii").read().strip()
        except OSError:
            continue
        try:
            model = open(f"{path}/device/model", encoding="utf-8",
                         errors="replace").read().strip()
        except OSError:
            model = "?"
        print(f"  /dev/{name:<9}{sectors * SECTOR / 1024 ** 3:>7.1f}G  "
              f"可移动={removable}  {model}")


def list_disks() -> None:
    if IS_WIN:
        list_disks_win()
        print("  下一步：\n"
              "    python tools\\burn_wav.py --device \\\\.\\PhysicalDrive<盘号> --track 5 --dry-run")
    else:
        list_disks_unix()
        print("  下一步：\n"
              "    sudo python3 tools/burn_wav.py --device /dev/sdX --track 5 --dry-run")


def mounted_on_unix(dev: Path) -> list[str]:
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
    ap.add_argument("--device", type=Path, default=None,
                    help="整块设备：Linux /dev/sdX；Windows \\\\.\\PhysicalDriveN（--list 可查盘号）")
    ap.add_argument("--list", action="store_true",
                    help="列出这台机器的物理盘（只读、不用管理员），用来找盘号")
    ap.add_argument("--wav", type=Path, default=None,
                    help="要烧的 WAV；不给则用 暂存/wav_test/track<--track>.wav"
                         "（--free-song 时先用 free_song.wav）")
    ap.add_argument("--track", type=int, default=None, choices=(1, 2, 3, 4, 5),
                    help="段模式：烧到第几段（1..4 = PICTURE_1..4；5 = FREE_SONG），默认 1")
    ap.add_argument("--free-song", action="store_true",
                    help="段模式：等价于 --track 5，写到 FREE_SONG 的首扇区（默认 LBA 500000）")
    ap.add_argument("--sector", "--lba", dest="lba", type=int, default=None,
                    help="裸扇区模式：直接写到这个 LBA，不读 RTL、不做段间越界检查")
    ap.add_argument("--dry-run", action="store_true", help="只打印计划，不写设备")
    ap.add_argument("--confirm", action="store_true",
                    help="Windows 上真写时的确认开关（裸扇区写物理盘不可撤销）")
    args = ap.parse_args()

    # ---- 先处理 --list：它不需要 --device，也不碰任何盘 ----
    if args.list:
        list_disks()
        return 0
    if args.device is None:
        raise SystemExit("缺少 --device。先查盘号：\n"
                         "  python tools\\burn_wav.py --list\n"
                         "再指定设备：\n"
                         "  python tools\\burn_wav.py --device \\\\.\\PhysicalDrive2 --track 5 --dry-run")

    # ---- 模式判定 ----
    raw_mode = args.lba is not None
    if raw_mode and (args.track is not None or args.free_song):
        raise SystemExit("--sector/--lba 是裸扇区模式，不能和 --track/--free-song 同时用")
    if args.free_song and args.track not in (None, 5):
        raise SystemExit("--free-song 与 --track N（N=1..4）冲突")
    if not raw_mode:
        args.track = 5 if args.free_song else (args.track or 1)

    dev: Path = args.device
    if args.wav is None:
        if args.free_song:
            cand = REPO / "暂存/wav_test/free_song.wav"
            if not cand.is_file():
                cand = REPO / "暂存/wav_test/track5.wav"
            args.wav = cand
        elif raw_mode:
            args.wav = REPO / "暂存/wav_test/track1.wav"
        else:
            args.wav = REPO / f"暂存/wav_test/track{args.track}.wav"
    if not args.wav.is_file():
        raise SystemExit(f"WAV 不存在：{args.wav}\n"
                         f"先跑 python3 tools/make_test_wav.py --track {args.track or 5}\n"
                         f"或直接用 --wav 指定")

    lbas = None
    if not raw_mode:
        try:
            lbas = picture_lbas()
        except SystemExit:
            if not args.free_song:
                raise
            # --free-song 允许 RTL 解析失败：退回公认的 500000
            print(f"⚠ 解析 RTL 失败，FREE_SONG 用兜底值 LBA {FREE_SONG_LBA}")

    if raw_mode:
        lba, lba_src = args.lba, "--sector/--lba 显式指定（裸扇区模式）"
    elif lbas:
        lba = lbas[args.track - 1]
        lba_src = f"{RTL_SEL.name} 的 parameter {PICTURE_PARAMS[args.track - 1]}"
    else:
        lba, lba_src = FREE_SONG_LBA, "内置兜底值（未解析 RTL）"

    channels, width, rate, frames = wav_facts_checked(args.wav)
    payload = args.wav.read_bytes()
    padded = payload + b"\x00" * ((-len(payload)) % SECTOR)
    sectors = len(padded) // SECTOR
    offset = lba * SECTOR
    digest = hashlib.sha256(payload).hexdigest()

    print("=" * 58)
    print(f"  设备     : {dev}")
    print(f"  WAV      : {args.wav}")
    if raw_mode:
        print("  段号     : 裸扇区模式（不解析 RTL）")
    else:
        seg_name = PICTURE_PARAMS[args.track - 1]
        seg_kind = "自动展播 FREE_SONG" if args.track == 5 else f"第 {args.track} 页"
        print(f"  段号     : {args.track}（{seg_kind}，{seg_name}）")
    print(f"  格式     : PCM {width * 8} bit / {rate} Hz / {channels} 声道，"
          f"{frames / rate:.2f} s")
    print(f"  大小     : {len(payload)} 字节（补齐后 {len(padded)} = {sectors} 扇区）")
    print(f"  写入位置 : LBA {lba} 起（字节偏移 {offset}），"
          f"占用到 LBA {lba + sectors - 1}（{sectors / 2048:.2f} MiB）")
    print(f"  源 sha256: {digest}")
    print("=" * 58)
    print(f"  起始扇区取自：{lba_src}")

    if lbas:
        print("  RTL 里的五段位置：")
        for i, v in enumerate(lbas, 1):
            mark = "   ← 本次" if (not raw_mode and i == args.track) else ""
            print(f"    {PICTURE_PARAMS[i - 1]:<9s} = LBA {v}{mark}")
        # 越界保护：这段 WAV 不能盖住"下一段"的起点，否则两页听到的是同一段
        # 被截断的音频（而且改一段就把别人写坏了）
        higher = sorted(v for v in lbas if v > lba)
        if higher and lba + sectors > higher[0]:
            if raw_mode:
                print(f"\n⚠ 警告：这段会盖住下一段起点 LBA {higher[0]}"
                      f"（裸扇区模式不拦，自己确认）")
            else:
                raise SystemExit(
                    f"\n中止：这段 WAV 占 LBA {lba}..{lba + sectors - 1}，"
                    f"会盖住下一段的起点 LBA {higher[0]}。\n"
                    f"      要么缩短音频（make_test_wav.py --seconds 调小），"
                    f"要么把 PICTURE_x / FREE_SONG 的间距排开。")

    # ---- 设备探测（两个平台各一套）----
    win_disk = None
    if IS_WIN:
        disk_no = win_disk_number(dev)
        win_disk = _WinDisk(str(dev))
        info = win_disk.geometry()
        sector_size = info["sector_size"]
        if sector_size != SECTOR:
            raise SystemExit(f"设备逻辑扇区是 {sector_size} 字节，不是 512，"
                             f"本脚本的 LBA→偏移换算不适用")
    else:
        if not dev.exists():
            raise SystemExit(f"设备不存在：{dev}")
        if not dev.is_block_device():
            raise SystemExit(f"{dev} 不是块设备")
        info = block_info_unix(dev)
        sector_size = SECTOR

    cap = info["sectors"] * SECTOR
    print(f"  型号     : {info['model']}")
    print(f"  可移动   : {info['removable']}（必须是 1）")
    print(f"  容量     : {cap / 1024 / 1024:.0f} MiB")

    if info["removable"] != "1":
        raise SystemExit(f"中止：{dev} 不是可移动设备，拒绝写入")
    if offset + len(padded) > cap:
        raise SystemExit(f"中止：WAV 超出设备容量（需要写到 {offset + len(padded)} 字节，"
                         f"设备只有 {cap}）")
    if offset <= BMP_IMAGE_END * SECTOR:
        print("⚠ 警告：起始扇区落在缩放测试 BMP 镜像（LBA 0..11853）里面，"
              "会覆盖页面图；确认这是你要的再继续")

    if not IS_WIN:
        busy = mounted_on_unix(dev)
        if busy:
            raise SystemExit("中止：设备被挂载着，先 umount：\n  " + "\n  ".join(busy))

    if args.dry_run:
        print("\n--dry-run：只检查，不写设备。")
        return 0

    if IS_WIN and not args.confirm:
        raise SystemExit("\n中止：Windows 上写物理盘需要加 --confirm。\n"
                         "      建议先加 --dry-run 看一眼计划，再真写。")
    if not IS_WIN and os.geteuid() != 0:
        raise SystemExit("需要 root 才能写块设备，请用 sudo 运行")

    # ---- 真正写 ----
    print("\n开始写入……")
    if IS_WIN:
        win_disk.open(write=True)
        try:
            for note in win_disk.lock_and_dismount(disk_no):
                print(f"  卷处理: {note}")
            win_disk.seek_write(offset, padded)
            first = win_disk.seek_read(offset, min(SECTOR, len(padded)))
            last = win_disk.seek_read(offset + len(padded) - min(SECTOR, len(padded)),
                                      min(SECTOR, len(padded)))
        finally:
            win_disk.close()
        total = len(padded)
    else:
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

            # 回读校验：首扇区、末扇区
            os.lseek(fd, offset, os.SEEK_SET)
            first = os.read(fd, min(SECTOR, len(padded)))
            os.lseek(fd, offset + len(padded) - min(SECTOR, len(padded)), os.SEEK_SET)
            last = os.read(fd, min(SECTOR, len(padded)))
        finally:
            os.close(fd)
    if IS_WIN:
        print(f"  已写 {total:>9} / {len(padded)} 字节")

    ok_first = first == padded[:len(first)]
    ok_last = last == padded[-len(last):]
    print(f"  回读首扇区 : {'一致' if ok_first else '不一致'}")
    print(f"  回读末扇区 : {'一致' if ok_last else '不一致'}")
    if not (ok_first and ok_last):
        raise SystemExit("校验失败：写入内容与源文件不一致")

    print("\n完成。上板检查顺序：")
    print("  1) 卡插回板子，烧 project/build/top_adc/top_adc.bit 或 top/top.bit")
    print("  2) 上电即在播第 1 页的音频；翻页应换成对应页的音频")
    print("     （四页要各烧一次 --track 1..4，只烧一段的话四页听起来一样；")
    print("       自动展播共用第 5 段，要单独 --free-song 烧一次，否则轮播时是空白/静音）")
    print("  3) 进「自动展播」模式（KEY0 切到 mode=1）应立刻听到第 5 段")
    print("  4) 听不到就查：卡是否识别、第 5 段是否真的在 LBA 500000、RTL 的 FREE_SONG 值")
    return 0


if __name__ == "__main__":
    sys.exit(main())
