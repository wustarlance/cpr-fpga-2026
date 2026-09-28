#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_bmp.py -- 检查 BMP 是否符合参考工程的读图要求

参考工程 (lab_ex4_tf / lab_ex5_i2s) 用【物理扇区扫描 + 头部匹配】找图,
bmp_read.v 的 header_match 会逐项比对。任何一项不符, 图会被【静默跳过】--
不报错, 只表现为"卡里明明有图, 屏幕却全黑/少图"。

本脚本把这件事提前到电脑上, 让素材一做完就能自检。

检查项
------
  1. 魔数           必须是 'BM'
  2. 宽 x 高        必须是 640 x 480
  3. biHeight 符号  ★ 必须【为正】(正=bottom-up)。
                       负数是 top-down, height[15:0] 对不上 480, 会被静默跳过
  4. 位深           必须 24 (真彩色)
  5. 压缩方式       必须 0 (BI_RGB, 非压缩)
  6. 宽 % 4         必须为 0。行按 4 字节对齐, 否则填充字节会被当像素 -> 图斜切
  7. 文件大小       应与 头 + 调色板 + stride*高 一致 (查截断/多余)

用法
----
    python3 check_bmp.py output_bmp/*.bmp
    python3 check_bmp.py output_bmp/                 # 传目录则自动找 *.bmp
    python3 check_bmp.py -q img/*.bmp                # 只输出不合规的

退出码: 0 = 全部合规, 1 = 有不合规 (可直接用于脚本串联)
"""

import argparse
import glob
import os
import struct
import sys

WANT_W = 640
WANT_H = 480
WANT_BITS = 24
WANT_COMPR = 0


def expected_stride(width, bits):
    """BMP 行字节数: 按 4 字节对齐。"""
    return (((width * bits) + 31) & ~31) >> 3


def check_one(path):
    """返回 (是否合规, 问题列表, 信息字典)。读不到文件时返回 None。"""
    try:
        with open(path, 'rb') as f:
            head = f.read(54)
            if len(head) < 54:
                return False, ['文件太短, 不足 54 字节的 BMP 头'], {}
            magic = head[0:2]
            file_size = struct.unpack('<I', head[2:6])[0]
            data_off = struct.unpack('<I', head[10:14])[0]
            dib_size = struct.unpack('<I', head[14:18])[0]
            width = struct.unpack('<i', head[18:22])[0]
            height = struct.unpack('<i', head[22:26])[0]   # 有符号!
            planes = struct.unpack('<H', head[26:28])[0]
            bits = struct.unpack('<H', head[28:30])[0]
            compr = struct.unpack('<I', head[30:34])[0]
            f.seek(0, os.SEEK_END)
            real_size = f.tell()
    except OSError as e:
        return False, ['无法读取: %s' % e], {}

    info = {
        'magic': magic, 'width': width, 'height': height, 'bits': bits,
        'compr': compr, 'file_size': file_size, 'real_size': real_size,
        'data_off': data_off, 'dib_size': dib_size, 'planes': planes,
    }
    problems = []

    # 1. 魔数
    if magic != b'BM':
        problems.append("魔数不是 BM (实际 %r) -> 扇区扫描会直接跳过" % magic)

    # 2. 宽高
    if width != WANT_W:
        problems.append("宽 = %d, 应为 %d" % (width, WANT_W))
    if abs(height) != WANT_H:
        problems.append("高 = %d, 应为 ±%d" % (height, WANT_H))

    # 3. ★ biHeight 符号
    if height < 0:
        problems.append(
            "★ biHeight = %d 是【负】的 (top-down)。参考工程要求为正 (bottom-up); "
            "会被 header_match 静默跳过" % height)

    # 4. 位深
    if bits != WANT_BITS:
        problems.append("位深 = %d, 应为 %d" % (bits, WANT_BITS))

    # 5. 压缩
    if compr != WANT_COMPR:
        problems.append("压缩方式 = %d, 应为 %d (非压缩 BI_RGB)" % (compr, WANT_COMPR))

    # 6. 宽 % 4
    if width % 4 != 0:
        problems.append("宽 %d %% 4 = %d, 应为 0 -> 行填充会被当像素, 图像斜切"
                        % (width, width % 4))

    # 7. 文件大小自洽
    if bits > 0 and width > 0 and abs(height) > 0:
        stride = expected_stride(width, bits)
        pal = 0
        if bits <= 8:
            pal = (1 << bits) * 4
        expect = data_off + stride * abs(height)
        info['stride'] = stride
        info['expected_size'] = expect
        if real_size != expect:
            problems.append("文件实际 %d 字节, 按 stride=%d 推算应为 %d (差 %+d) "
                            "-> 可能截断或格式不符"
                            % (real_size, stride, expect, real_size - expect))
        if file_size != real_size:
            problems.append("BMP 头声明 %d 字节, 实际 %d 字节 (差 %+d)"
                            % (file_size, real_size, real_size - file_size))

    return (len(problems) == 0), problems, info


def expand_inputs(items):
    """把目录展开成其中的 *.bmp。

    返回 (待检查文件列表, 找不到的输入列表)。
    区分"路径不存在"与"BMP 不合规", 避免把打错的路径报成格式问题。
    """
    files, missing = [], []
    for it in items:
        if os.path.isdir(it):
            hits = sorted(glob.glob(os.path.join(it, '*.bmp')))
            if hits:
                files.extend(hits)
            else:
                missing.append(it + '/  (目录里没有 .bmp)')
        elif os.path.isfile(it):
            files.append(it)
        else:
            hits = sorted(glob.glob(it))
            if hits:
                files.extend(hits)
            else:
                missing.append(it)
    return files, missing


def main():
    ap = argparse.ArgumentParser(
        description="检查 BMP 是否符合参考工程读图要求 (640x480, 24bit, 非压缩, biHeight 为正)")
    ap.add_argument('paths', nargs='+', help='BMP 文件或目录 (支持通配符)')
    ap.add_argument('-q', '--quiet', action='store_true',
                    help='只输出不合规的文件')
    args = ap.parse_args()

    files, missing = expand_inputs(args.paths)

    if missing:
        print("以下输入没找到 (不是 BMP 格式问题, 请检查路径):")
        for m in missing:
            print("  ? %s" % m)
        print()

    if not files:
        print("没有找到任何可检查的 .bmp 文件")
        return 1

    bad = 0
    saw_negative_height = False
    for path in files:
        res = check_one(path)
        if res is None:
            continue
        ok, problems, info = res
        if ok:
            if not args.quiet:
                print("[OK]   %s" % path)
                print("       宽=%d 高(biHeight)=%+d 位深=%d 压缩=%d stride=%d  %d 字节"
                      % (info['width'], info['height'], info['bits'], info['compr'],
                         info.get('stride', -1), info['real_size']))
        else:
            bad += 1
            if info and info.get('height', 0) < 0:
                saw_negative_height = True
            print("[FAIL] %s" % path)
            if info:
                print("       宽=%d 高(biHeight)=%+d 位深=%d 压缩=%d 实际 %d 字节"
                      % (info['width'], info['height'], info['bits'],
                         info['compr'], info['real_size']))
            for p in problems:
                print("       - %s" % p)

    print()
    print("共检查 %d 个文件: %d 个合规, %d 个不合规。" % (len(files), len(files) - bad, bad))
    if saw_negative_height:
        print("提示: biHeight 为负是 top-down BMP。用 convert_images_to_bmp.py 重新转换可修正。")
    if missing:
        print("另有 %d 个输入路径没找到 (见上方)。" % len(missing))
    return 1 if (bad or missing) else 0


if __name__ == '__main__':
    sys.exit(main())
