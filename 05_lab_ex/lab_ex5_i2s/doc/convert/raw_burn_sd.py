#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
raw_burn_sd.py —— 把 BMP 裸写到 TF 卡最前面（参考工程按【物理扇区】扫描）

为什么需要它
============
参考工程 lab_ex5_i2s 读图走的是【物理扇区扫描】，不解析 FAT 文件系统。
而 sync_to_sd.py / sync_to_sd_linux.py 做的是【普通文件拷贝】—— 图片落在
FAT32 数据区（典型在扇区 8000 之后），扫描够不着。

实测症状（2026-10-09）：
    数码管先显示 2 约 30 秒（扫描跑完 131071 个扇区号）
    然后变成 1（IDLE）不动，从未出现 3/4（读图状态）
    → img_found_count = 0，一张都没找到

本脚本把图片按 512 字节对齐【裸写】到卡的最前面：

    扇区 0      ← 第 1 张（含 458 字节 0 补齐）
    扇区 1801   ← 第 2 张
    扇区 3602   ← 第 3 张
    扇区 5403   ← 第 4 张

为什么必须补齐
--------------
扫描每找到一张图就跳过 (file_len + 511) >> 9 个扇区：

    921,654 字节 → ceil(921654/512) = 1801 扇区 = 922,112 字节
    需补 922112 - 921654 = 458 字节的 0

不补齐，下一张就不会落在跳转点上。

⚠️ 这会覆盖卡的 FAT32 文件系统
----------------------------
FPGA 按物理扇区扫，不看文件系统，所以能用；但要插回电脑当普通 U 盘用时
需要重新格式化。**因此本脚本要求先 umount。**

用法
====
    # 1. 先卸载（文件系统会被破坏，必须卸载后再写，否则内核缓存会覆盖）
    udisksctl unmount -b /dev/sda1        # 或 sudo umount /media/$USER/E4BB-9173

    # 2. 先干跑，确认要写什么
    sudo python3 raw_burn_sd.py /dev/sda --dry-run

    # 3. 真写
    sudo python3 raw_burn_sd.py /dev/sda

    # 4. 验证布局（脚本会自动回读校验；也可手工再查）
    sudo dd if=/dev/sda bs=512 count=1 2>/dev/null | head -c 2   # 应为 BM

⚠️ 目标必须是【整盘 /dev/sda】，不是分区 /dev/sda1
--------------------------------------------------
实测这张卡的分区表：sda1 从扇区 8192 开始（偏移 4 MB）。
写 /dev/sda1 会把图片放到卡的扇区 8192，而参考工程是从【卡的扇区 0】
开始扫的。写整盘才能让第 1 张正好落在扇区 0。

（卸载后 /dev/sda1 节点会消失，这也是必须用 /dev/sda 的原因之一。）

安全设计（沿用 sync_to_sd_linux.py 的四道闸门）
=============================================
    闸门 1  必须是整盘块设备（分区默认拒绝，--allow-partition 可放行）
    闸门 2  该设备不能正处于挂载状态（含其任何分区）—— 防止写坏正在用的盘
    闸门 3  不得是本机系统盘（与 / 同源者拒绝）
    闸门 4  设备必须 removable=1（--force-removable 可放行）
    最后    要把设备名原样敲一遍作为最终确认
"""

import argparse
import os
import re
import subprocess
import sys

# ---------------------------------------------------------------------------
# 项目工作区（拒绝往这里写 —— 2026-09-22 事故的教训）
# ---------------------------------------------------------------------------
REPO_DIR = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))))   # .../FPGA_Contest

DEFAULT_SOURCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "output_bmp")
SECTOR = 512


def die(msg, code=1):
    print(f"\n❌ {msg}", file=sys.stderr)
    sys.exit(code)


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


# ---------------------------------------------------------------------------
# 读取 /proc/mounts
# ---------------------------------------------------------------------------
def read_mounts():
    out = []
    with open("/proc/mounts", encoding="utf-8", errors="replace") as f:
        for line in f:
            p = line.split()
            if len(p) >= 3:
                out.append((p[0], p[1], p[2]))   # source, mountpoint, fstype
    return out


def device_of(path):
    """把挂载点解析成设备名"""
    for src, mp, _ in read_mounts():
        if os.path.realpath(mp) == os.path.realpath(path):
            return src
    return None


def mounted_source_of_root():
    for src, mp, _ in read_mounts():
        if mp == "/":
            return src
    return None


# ---------------------------------------------------------------------------
# 四道闸门
# ---------------------------------------------------------------------------
def is_partition(dev):
    """是不是分区（分区在 sysfs 下有 partition 文件）"""
    m = re.match(r"^/dev/(.+)$", dev)
    return bool(m) and os.path.exists(f"/sys/class/block/{m.group(1)}/partition")


def partition_start(dev):
    """分区起始扇区（整盘返回 None）"""
    m = re.match(r"^/dev/(.+)$", dev)
    if not m:
        return None
    try:
        with open(f"/sys/class/block/{m.group(1)}/start") as f:
            return int(f.read().strip())
    except OSError:
        return None


def whole_disk_of(dev):
    m = re.match(r"^(/dev/sd[a-z]|/dev/mmcblk[0-9]+|/dev/nvme[0-9]+n[0-9]+)", dev)
    return m.group(1) if m else dev


def gate_device_node(dev, allow_partition=False):
    if not re.match(r"^/dev/(sd[a-z][0-9]*|mmcblk[0-9]+(p[0-9]+)?|nvme[0-9]+n[0-9]+(p[0-9]+)?)$", dev):
        die(f"闸门 1 未过：{dev} 不是可识别的块设备节点\n"
            f"    （应为 /dev/sda、/dev/mmcblk0 这类）")
    if not os.path.exists(dev):
        die(f"闸门 1 未过：{dev} 不存在")

    # ⚠️ 分区不是从扇区 0 开始的 —— 写分区会把图片放到错误的物理位置
    if is_partition(dev) and not allow_partition:
        st = partition_start(dev)
        die(
            f"闸门 1 未过：{dev} 是【分区】，不是整盘\n"
            f"\n"
            f"    该分区从扇区 {st} 开始（字节偏移 {st*SECTOR if st else '?'}）。\n"
            f"    参考工程按【卡的物理扇区】扫描、从扇区 0 开始 ——\n"
            f"    写分区会把图片放到卡的扇区 {st}，而不是扫描要看的起点。\n"
            f"\n"
            f"    ✅ 正确用法：写整盘\n"
            f"         {whole_disk_of(dev)}\n"
            f"    （若你确知分区偏移、有意从分区起点写，加 --allow-partition）"
        )
    st = partition_start(dev)
    if st is not None:
        print(f"  ⚠️  闸门 1  {dev} 是分区（从扇区 {st} 开始），已按 --allow-partition 放行")
    else:
        print(f"  ✅ 闸门 1  整盘设备：{dev}（扇区 0 起点正确）")


def gate_not_mounted(dev):
    for src, mp, _ in read_mounts():
        if src == dev or src.startswith(dev):
            die(f"闸门 2 未过：{dev} 仍处于挂载状态（{src} → {mp}）\n"
                f"    请先卸载：sudo umount {mp}\n"
                f"    不卸载就写，内核缓存会把你的写入覆盖掉。")
    print(f"  ✅ 闸门 2  未挂载（可以安全裸写）")


def gate_not_system_disk(dev):
    root_src = mounted_source_of_root()
    if root_src:
        # /dev/nvme1n1p4 → 取 /dev/nvme1n1；/dev/sda1 → /dev/sda
        def base(d):
            m = re.match(r"^(/dev/(?:sd[a-z]|mmcblk[0-9]+|nvme[0-9]+n[0-9]+))", d)
            return m.group(1) if m else d
        if base(dev) == base(root_src):
            die(f"闸门 3 未过：{dev} 与系统盘同源（/ 挂在 {root_src}）")
    print(f"  ✅ 闸门 3  与系统盘不同源（/ 在 {root_src}）")


def gate_removable(dev, force):
    base = re.match(r"^(/dev/(?:sd[a-z]|mmcblk[0-9]+|nvme[0-9]+n[0-9]+))", dev).group(1)
    name = os.path.basename(base)
    try:
        with open(f"/sys/block/{name}/removable") as f:
            rm = f.read().strip()
    except OSError:
        rm = "?"
    if rm == "1":
        print(f"  ✅ 闸门 4  {name} 报告 removable=1")
    elif force:
        print(f"  ⚠️  闸门 4  {name} removable={rm}，但 --force-removable 已放行")
    else:
        die(f"闸门 4 未过：{name} 报告 removable={rm}（不是可移动设备）\n"
            f"    少数读卡器会报 0；确认无误可加 --force-removable 放行。")


# ---------------------------------------------------------------------------
# BMP 校验（与 check_bmp.py 同口径）
# ---------------------------------------------------------------------------
def read_bmp_meta(path):
    with open(path, "rb") as f:
        h = f.read(54)
    if len(h) < 54:
        return None
    if h[0:2] != b"BM":
        return None
    file_len = int.from_bytes(h[2:6], "little")
    off = int.from_bytes(h[10:14], "little")
    w = int.from_bytes(h[18:22], "little", signed=True)
    ht = int.from_bytes(h[22:26], "little", signed=True)
    bits = int.from_bytes(h[28:30], "little")
    comp = int.from_bytes(h[30:34], "little")
    return dict(file_len=file_len, pixel_offset=off, width=w, height=ht,
                bit_count=bits, compression=comp)


def main():
    ap = argparse.ArgumentParser(
        description="把 BMP 按 512 字节对齐裸写到 TF 卡最前面（参考工程按物理扇区扫描）",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("device",
                    help="目标【整盘】设备，如 /dev/sda（不是 /dev/sda1！必须先 umount）")
    ap.add_argument("-s", "--source", default=DEFAULT_SOURCE,
                    help=f"存放 BMP 的目录（默认 {DEFAULT_SOURCE}）")
    ap.add_argument("-n", "--num", type=int, default=4, help="最多写几张（默认 4）")
    ap.add_argument("--start-sector", type=int, default=0, help="起始扇区（默认 0）")
    ap.add_argument("--dry-run", action="store_true", help="只打印计划，不写入")
    ap.add_argument("--force-removable", action="store_true",
                    help="放行 removable=0 的设备")
    ap.add_argument("--allow-partition", action="store_true",
                    help="放行分区设备（默认拒绝 —— 分区不从扇区 0 开始）")
    ap.add_argument("-y", "--yes", action="store_true", help="跳过最终确认（自动化用）")
    args = ap.parse_args()

    print("=" * 68)
    print(" raw_burn_sd.py —— 把 BMP 裸写到 TF 卡最前面")
    print("=" * 68)
    print(f"  目标设备 : {args.device}")
    print(f"  图片源   : {args.source}")
    print(f"  起始扇区 : {args.start_sector}")
    print(f"  最多张数 : {args.num}")
    print(f"  模式     : {'干跑（不会写入）' if args.dry_run else '实际写入'}")
    print()

    # ---- 四道闸门 ----
    print("安全校验：")
    gate_device_node(args.device, args.allow_partition)
    gate_not_mounted(args.device)
    gate_not_system_disk(args.device)
    gate_removable(args.device, args.force_removable)
    print()

    # ---- 收集并校验图片 ----
    if not os.path.isdir(args.source):
        die(f"图片源目录不存在：{args.source}")
    files = sorted(f for f in os.listdir(args.source)
                   if f.lower().endswith(".bmp")
                   and os.path.isfile(os.path.join(args.source, f)))
    if not files:
        die(f"{args.source} 里没有 .bmp")

    plan = []
    sector = args.start_sector
    for name in files[: args.num]:
        path = os.path.join(args.source, name)
        meta = read_bmp_meta(path)
        if meta is None:
            die(f"{name} 不是合法 BMP")
        bad = []
        if meta["width"] != 640:      bad.append(f"宽={meta['width']}（要 640）")
        if meta["height"] != 480:     bad.append(f"高={meta['height']}（要 480，且必须为正）")
        if meta["bit_count"] != 24:   bad.append(f"位深={meta['bit_count']}（要 24）")
        if meta["compression"] != 0:  bad.append(f"压缩={meta['compression']}（要 0）")
        if bad:
            die(f"{name} 不符合参考工程读图要求：\n    " + "\n    ".join(bad))

        size = os.path.getsize(path)
        nsec = (size + SECTOR - 1) // SECTOR
        pad = nsec * SECTOR - size
        plan.append(dict(name=name, path=path, size=size, nsec=nsec,
                         pad=pad, sector=sector))
        sector += nsec

    print("写入计划：")
    print(f"  {'扇区':>8}  {'字节偏移':>12}  {'补齐':>6}  {'扇区数':>6}  文件")
    for e in plan:
        print(f"  {e['sector']:>8}  {e['sector']*SECTOR:>12}  {e['pad']:>6}  "
              f"{e['nsec']:>6}  {e['name']}")
    total = sum(e["nsec"] for e in plan)
    print(f"\n  合计 {len(plan)} 张，{total} 扇区，约 {total*SECTOR/1048576:.1f} MB")
    print(f"  ⚠️  这会覆盖 {args.device} 最前面 {total*SECTOR/1048576:.1f} MB 的内容")
    print()

    if args.dry_run:
        print("（干跑结束，未写入任何东西）")
        return

    # ---- 最终确认 ----
    if not args.yes:
        print(f"要把上面 {len(plan)} 张图裸写到 {args.device}，此操作不可逆。")
        typed = input(f"请把设备名原样敲一遍以确认（{args.device}）：").strip()
        if typed != args.device:
            die("设备名不一致，已取消。")

    # ---- 写入 ----
    print("\n开始写入...")
    try:
        fd = os.open(args.device, os.O_WRONLY)
    except PermissionError:
        die(f"打不开 {args.device}（权限不够）\n"
            f"    请用 sudo 运行本脚本：sudo python3 {os.path.basename(__file__)} {args.device}")
    except OSError as e:
        die(f"打不开 {args.device}：{e}")

    try:
        for e in plan:
            os.lseek(fd, e["sector"] * SECTOR, os.SEEK_SET)
            with open(e["path"], "rb") as f:
                data = f.read()
            written = 0
            while written < len(data):
                written += os.write(fd, data[written:])
            # 补齐到 512 边界
            if e["pad"]:
                os.write(fd, b"\x00" * e["pad"])
            os.fsync(fd)
            print(f"  ✅ 扇区 {e['sector']:>8}  ←  {e['name']}  "
                  f"({e['size']} B + {e['pad']} B 补齐)")
    finally:
        os.close(fd)

    # ---- 回读校验 ----
    print("\n回读校验：")
    fd = os.open(args.device, os.O_RDONLY)
    try:
        ok = True
        for e in plan:
            os.lseek(fd, e["sector"] * SECTOR, os.SEEK_SET)
            magic = os.read(fd, 2)
            mark = "✅" if magic == b"BM" else "❌"
            if magic != b"BM":
                ok = False
            print(f"  {mark} 扇区 {e['sector']:>8} 读到 {magic!r}")
    finally:
        os.close(fd)

    print()
    if ok:
        print("✅ 全部写入并校验通过。")
        print("   → 把卡插回 FPGA，重烧位流，数码管应出现 3/4")
        print("   → 卡想当普通 U 盘用需重新格式化（文件系统已被覆盖）")
    else:
        die("有扇区回读不是 BM —— 写入可能失败，请重跑或换卡")


if __name__ == "__main__":
    main()
