#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
sync_to_sd_linux.py -- 厂商 sync_to_sd.py 的 Linux 移植版 (安全加固)

原版 (sync_to_sd.py) 只认 Windows 盘符 (E:\\), 在 Linux 上跑不了。
本移植版改为接受【挂载点路径】, 三步行为与原版一致:

  1. 破坏卡上旧 BMP 的魔数 (BM -> XX)
  2. 清空卡上根目录
  3. 按文件名排序取最多 N 张, 加序号前缀后拷入

为什么这三步是必要的
--------------------
参考工程读图用的是【物理扇区扫描】, 不是解析 FAT 目录。所以:
  - 已删除但扇区数据仍在的旧图, 必须破坏其魔数, 否则会被误扫到;
  - 新图按序号命名, 是为了让物理扇区尽量连续。


!! 关于本脚本的安全设计 (2026-09-22 事故后重写) !!
==================================================
早期版本的"是不是挂载点"判断用 st_dev 与父目录比较。这个判据【会被 bind mount 骗过】:
只要某个目录被 bind mount 上来, 它的 st_dev 就与父目录不同, 于是被误判成"卡",
结果真去清空了那个目录。本次事故正是这样删掉了整个项目目录。

现在的判据改成【看挂载源设备】, 四道闸门全部通过才动手:

  闸门 1  目标必须在 /proc/mounts 里, 且挂载源【不能与 / 同源】
          (bind mount 与 / 同源, 被这一条拦死)
  闸门 2  挂载源必须是真实块设备节点 (/dev/sd*, /dev/mmcblk*, /dev/disk/by-id/*)
          不能是 overlay / tmpfs / none / fuse 之类
  闸门 3  该设备必须报告 removable=1 (U 盘/读卡器都满足;
          少数读卡器报 0, 可用 --force-removable 显式放行)
  闸门 4  目标路径不得位于本项目工作区内 (硬编码拒绝)

最后还要求把【挂载源设备名原样敲一遍】作为最终确认。--dry-run 不做任何写入。
"""

import argparse
import glob
import os
import shutil
import sys

# 硬拒绝: 绝不允许当作 SD 卡操作的路径(含本项目工作区)
FORBIDDEN_PREFIXES = (
    '/home/starlance/FPGA_Contest',
    '/home', '/root', '/boot', '/dev', '/etc', '/usr', '/var',
    '/sys', '/proc', '/run', '/opt', '/srv', '/bin', '/sbin', '/lib',
)

SKIP_NAMES = {'System Volume Information', '$RECYCLE.BIN', 'LOST.DIR'}


# ----------------------------------------------------------------------
# 挂载信息工具
# ----------------------------------------------------------------------
def read_mounts():
    """返回 [(source, mountpoint, fstype), ...], 长路径在前便于前缀匹配。"""
    out = []
    try:
        with open('/proc/mounts', 'r') as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 3:
                    src = parts[0].replace('\\040', ' ')
                    mnt = parts[1].replace('\\040', ' ')
                    out.append((src, mnt, parts[2]))
    except OSError as e:
        print('[致命错误] 读不到 /proc/mounts: %s' % e)
        sys.exit(2)
    out.sort(key=lambda t: len(t[1]), reverse=True)
    return out


def find_mount(path):
    """找到覆盖 path 的最内层挂载, 返回 (source, mountpoint, fstype) 或 None。"""
    real = os.path.realpath(path)
    for src, mnt, fs in read_mounts():
        if real == mnt or real.startswith(mnt.rstrip('/') + '/'):
            return src, mnt, fs
    return None


def base_block_device(src):
    """把 /dev/sda1 归一成 /dev/sda; 不支持的类型返回 None。"""
    if src.startswith('/dev/disk/by-id/') or src.startswith('/dev/disk/by-path/'):
        try:
            return base_block_device(os.path.realpath(src))
        except OSError:
            return None
    if not src.startswith('/dev/'):
        return None
    name = os.path.basename(src)
    for prefix in ('mmcblk', 'nvme', 'sd', 'vd'):
        if not name.startswith(prefix):
            continue
        if prefix in ('mmcblk', 'nvme'):
            base = name.split('p')[0]
        else:
            base = name.rstrip('0123456789')
        return '/dev/' + base
    return None


def is_removable(base_dev):
    """查 /sys/block/<dev>/removable。返回 True/False/None(查不到)。"""
    if not base_dev:
        return None
    try:
        with open('/sys/block/%s/removable' % os.path.basename(base_dev)) as f:
            return f.read().strip() == '1'
    except OSError:
        return None


# ----------------------------------------------------------------------
# 四道闸门
# ----------------------------------------------------------------------
def preflight(target, force_removable=False):
    """全部通过则返回 (src, mnt, fs); 否则打印原因并退出。"""
    real = os.path.realpath(target)

    # 闸门 4: 工作区与系统路径黑名单
    for bad in FORBIDDEN_PREFIXES:
        if real == bad or real.startswith(bad.rstrip('/') + '/'):
            print('[致命错误 · 闸门4] 拒绝操作: %s' % real)
            print('           该路径位于受保护前缀之下: %s' % bad)
            sys.exit(1)

    if not os.path.isdir(real):
        print('[致命错误] 不是目录或不存在: %s' % real)
        print('           用 lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT 找到卡的真实挂载点。')
        sys.exit(1)

    # 闸门 1: 必须是挂载点, 且挂载源不能与 / 同源
    m = find_mount(real)
    if not m:
        print('[致命错误 · 闸门1] %s 不在 /proc/mounts 里, 不是挂载点。' % real)
        sys.exit(1)
    src, mnt, fs = m
    rm = find_mount('/')
    root_src = rm[0] if rm else None
    if src == root_src:
        print('[致命错误 · 闸门1] 拒绝操作!')
        print('           目标      : %s' % real)
        print('           挂载源    : %s' % src)
        print('           与 / 同源 : %s' % root_src)
        print('           这通常是 bind mount 或根文件系统上的普通目录, 不是 SD 卡。')
        print('           (这正是 2026-09-22 误删项目目录的原因, 已加固拦截)')
        sys.exit(1)

    # 闸门 2: 挂载源必须是真实块设备
    base = base_block_device(src)
    if base is None:
        print('[致命错误 · 闸门2] 挂载源不是真实块设备: %s (fstype=%s)' % (src, fs))
        print('           SD 卡应形如 /dev/sdX1 或 /dev/mmcblk0p1。')
        sys.exit(1)

    # 闸门 3: 设备须报告 removable
    rem = is_removable(base)
    if rem is not True:
        if force_removable:
            print('[警告 · 闸门3] %s 的 removable=%s, 但你给了 --force-removable, 放行。'
                  % (base, rem))
        else:
            print('[致命错误 · 闸门3] %s 不是可移动设备 (removable=%s)。' % (base, rem))
            print('           若确认这是读卡器(有些读卡器报 0), 加 --force-removable 重试。')
            sys.exit(1)

    return src, mnt, fs


# ----------------------------------------------------------------------
# 三个业务步骤
# ----------------------------------------------------------------------
def corrupt_old_bmp_headers(target_dir, dry_run=False):
    print("[1/3] 破坏旧 BMP 魔数 (BM -> XX): %s" % target_dir)
    files = sorted(glob.glob(os.path.join(target_dir, '*.bmp')))
    if not files:
        print("      卡上没有 .bmp, 跳过。")
        return 0
    count = 0
    for path in files:
        name = os.path.basename(path)
        try:
            with open(path, 'r+b') as f:
                if f.read(2) == b'BM':
                    if dry_run:
                        print("      [干跑] 会破坏: %s" % name)
                    else:
                        f.seek(0)
                        f.write(b'XX')
                        print("      [已破坏] %s" % name)
                    count += 1
                else:
                    print("      [跳过] %s (魔数不是 BM)" % name)
        except Exception as e:
            print("      [警告] 无法处理 %s: %s" % (name, e))
    print("      共处理 %d 个旧图。" % count)
    return count


def clean_target(target_dir, dry_run=False):
    print("[2/3] 清空卡上根目录: %s" % target_dir)
    count = 0
    for name in sorted(os.listdir(target_dir)):
        if name.startswith('.') or name in SKIP_NAMES:
            print("      [保留] %s" % name)
            continue
        path = os.path.join(target_dir, name)
        try:
            if dry_run:
                kind = "目录" if os.path.isdir(path) else "文件"
                print("      [干跑] 会删除%s: %s" % (kind, name))
            else:
                if os.path.isdir(path) and not os.path.islink(path):
                    shutil.rmtree(path)
                else:
                    os.remove(path)
                print("      [已删除] %s" % name)
            count += 1
        except Exception as e:
            print("      [警告] 无法删除 %s: %s" % (name, e))
    print("      共清除 %d 项。" % count)
    return count


def sync_new_images(source_dir, target_dir, max_count=4, dry_run=False):
    print("[3/3] 同步新图: %s -> %s" % (source_dir, target_dir))
    if not os.path.isdir(source_dir):
        print("      [错误] 源目录不存在: %s" % source_dir)
        return 0
    files = sorted(glob.glob(os.path.join(source_dir, '*.bmp')))
    if not files:
        print("      [错误] 源目录里没有 .bmp: %s" % source_dir)
        return 0
    picked = files[:max_count]
    if len(files) > max_count:
        print("      源目录共 %d 张, 按 -n %d 只取前 %d 张。"
              % (len(files), max_count, max_count))
    ok = 0
    for i, src in enumerate(picked):
        name = os.path.basename(src)
        dst_name = "%02d_%s" % (i, name)
        dst = os.path.join(target_dir, dst_name)
        try:
            if dry_run:
                print("      [干跑] %s -> %s" % (name, dst_name))
            else:
                shutil.copy2(src, dst)
                print("      [已写入] %s -> %s" % (name, dst_name))
            ok += 1
        except Exception as e:
            print("      [失败] %s: %s" % (name, e))
    print("      共写入 %d 张。" % ok)
    return ok


# ----------------------------------------------------------------------
def main():
    default_src = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), 'output_bmp')

    ap = argparse.ArgumentParser(
        description="FPGA SD 卡图片同步工具 (Linux 版, 安全加固, 防物理残留死锁)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="示例:\n"
               "  python3 sync_to_sd_linux.py /media/$USER/TFCARD --dry-run\n"
               "  python3 sync_to_sd_linux.py /media/$USER/TFCARD\n")
    ap.add_argument('target', help='SD 卡的【挂载点路径】, 例如 /media/starlance/TFCARD')
    ap.add_argument('-s', '--source', default=None,
                    help='存放 BMP 的源目录 (默认: 本脚本同级的 output_bmp)')
    ap.add_argument('-n', '--num', type=int, default=4, help='最多同步几张 (默认 4)')
    ap.add_argument('--dry-run', action='store_true', help='干跑: 只打印, 不写入')
    ap.add_argument('--force-removable', action='store_true',
                    help='放行 removable=0 的设备 (有些读卡器如此)')
    ap.add_argument('-y', '--yes', action='store_true',
                    help='跳过交互确认 (自动化用; 请先用 --dry-run 核对)')
    args = ap.parse_args()

    target = os.path.realpath(os.path.expanduser(args.target))
    source = (os.path.realpath(os.path.expanduser(args.source))
              if args.source else default_src)

    print("=" * 64)
    print("目标 SD 卡 (挂载点): %s" % target)
    print("图片源目录          : %s" % source)
    print("模式                : %s" % ("干跑 (不会写入)" if args.dry_run else "实际写入"))
    print("=" * 64)

    src, mnt, fs = preflight(target, args.force_removable)

    print("校验通过:")
    print("  挂载源设备 : %s   (fstype=%s)" % (src, fs))
    print("  挂载点     : %s" % mnt)
    print("  与 / 同源  : 否 ✅")
    print()

    if args.dry_run:
        print("(干跑模式: 以下操作都不会真正执行)\n")
    elif not args.yes:
        print("!! 接下来会【清空】上面这个挂载点上的所有内容 !!")
        print("   确认请把挂载源设备名原样敲一遍 (%s):" % src)
        try:
            typed = input("   > ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\n已取消。")
            return 1
        if typed != src:
            print("输入不匹配 (%r != %r), 已取消。" % (typed, src))
            return 1
        print()

    corrupt_old_bmp_headers(target, args.dry_run)
    print()
    clean_target(target, args.dry_run)
    print()
    n = sync_new_images(source, target, args.num, args.dry_run)

    if not args.dry_run:
        print("\n正在 flush 写入缓存 (os.sync)...")
        os.sync()
        print("完成。现在可以安全拔卡。")
    else:
        print("\n干跑结束。去掉 --dry-run 才会真正执行。")
        print("提示: 干跑报告显示将写入 %d 张。" % n)
    return 0


if __name__ == '__main__':
    sys.exit(main())
