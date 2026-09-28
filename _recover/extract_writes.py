#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
从 DSH 会话转录中恢复被误删的文件。

原理
----
会话转录 (.dsh/sessions/<proj>/<session>/session.v3.jsonl.zstd) 里保存了每一条
tool/call 的完整参数。其中:
  - write 工具 -> arguments 含 file_path + content  == 文件全文
  - edit  工具 -> arguments 含 file_path + old_string / new_string == 一次修改
因此把所有 write 按时间顺序回放, 再把所有 edit 依次叠加, 即可重建出每个文件的最终状态。

本脚本有两个模式:
  survey   只列出可恢复的文件路径与最终字节数, 不写任何东西
  restore  真正写入到 --out 指定的目录

用法
----
    python3 extract_writes.py survey
    python3 extract_writes.py restore --out /home/starlance/FPGA_Contest
"""

import argparse
import glob
import json
import os
import subprocess
import sys

SESSIONS_GLOB = os.path.expanduser(
    '~/.dsh/sessions/--home-starlance-FPGA_Contest--/*/session.v3.jsonl.zstd')


def iter_records():
    """按 (time, seq) 全局时序产出所有 tool/call 记录。"""
    records = []
    for path in sorted(glob.glob(SESSIONS_GLOB)):
        sess = os.path.basename(os.path.dirname(path))
        try:
            raw = subprocess.run(['zstd', '-dc', path],
                                 capture_output=True, check=True).stdout
        except Exception as e:
            print('  [警告] 解压失败 %s: %s' % (path, e), file=sys.stderr)
            continue
        for line in raw.split(b'\n'):
            if not line.strip():
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            if o.get('type') != 'tool/call':
                continue
            d = o.get('data') or {}
            name = d.get('name')
            if name not in ('write', 'edit'):
                continue
            try:
                args = json.loads(d.get('arguments') or '{}')
            except Exception:
                continue
            records.append({
                'time': o.get('time') or 0,
                'seq': o.get('seq') or 0,
                'session': sess,
                'tool': name,
                'args': args,
            })
    records.sort(key=lambda r: (r['time'], r['seq']))
    return records


def build(records):
    """先回放全部 write, 再按时间顺序叠加 edit。

    对"目标文件此前没有 write 记录"的情况, 尝试按内容认领被改过名的文件:
    若某个已重建文件的内容里含有本次 edit 的 old_string, 就把它认作该文件的前身。
    """
    files = {}
    pending = []
    for r in records:
        fp = r['args'].get('file_path')
        if not fp:
            continue
        if r['tool'] == 'write':
            files[fp] = r['args'].get('content', '')
        else:
            pending.append(r)

    applied = 0
    adopted = []
    failed = []

    for r in pending:
        a = r['args']
        fp = a['file_path']
        old = a.get('old_string', '')
        new = a.get('new_string', '')

        if fp not in files:
            # 尝试认领改名来源
            if old:
                cands = [p for p, c in files.items() if old in c]
                if len(cands) == 1:
                    files[fp] = files.pop(cands[0])
                    adopted.append((cands[0], fp))
            if fp not in files:
                failed.append((fp, '目标文件此前没有 write 记录, 也未能按内容认领'))
                continue

        cur = files[fp]
        if old == '':
            files[fp] = new
            applied += 1
            continue
        if old not in cur:
            failed.append((fp, 'old_string 未命中'))
            continue
        if a.get('replace_all'):
            files[fp] = cur.replace(old, new)
        else:
            files[fp] = cur.replace(old, new, 1)
        applied += 1

    return files, applied, failed, adopted


def main():
    ap = argparse.ArgumentParser(description='从 DSH 转录恢复被删文件')
    ap.add_argument('mode', choices=['survey', 'restore'])
    ap.add_argument('--out', default=None, help='恢复到哪个根目录 (restore 模式)')
    ap.add_argument('--root', default='/home/starlance/FPGA_Contest',
                    help='原项目根路径, 用于把绝对路径转成相对路径')
    args = ap.parse_args()

    print('扫描转录: %s' % SESSIONS_GLOB)
    records = iter_records()
    n_w = sum(1 for r in records if r['tool'] == 'write')
    n_e = sum(1 for r in records if r['tool'] == 'edit')
    print('共取到 write %d 条, edit %d 条\n' % (n_w, n_e))

    files, applied, failed = build(records)

    root = os.path.realpath(args.root)
    rows = []
    outside = 0
    for fp, content in sorted(files.items()):
        rp = os.path.realpath(fp)
        if rp.startswith(root + os.sep):
            rel = os.path.relpath(rp, root)
        else:
            rel = fp  # 项目外的文件
            outside += 1
        rows.append((rel, len(content.encode('utf-8')), content, rp.startswith(root + os.sep)))

    print('=' * 72)
    print('%d 个文件可重建  (共 %d 字节)' % (len(rows), sum(r[1] for r in rows)))
    print('edit 成功回放 %d 次, 失败 %d 次' % (applied, len(failed)))
    print('其中项目外文件 %d 个' % outside)
    print('=' * 72)
    for rel, size in rows:
        print('%9d  %s' % (size, rel))

    if failed:
        print('\n--- 未能回放的 edit (需人工处理) ---')
        seen = set()
        for fp, why in failed:
            key = (fp, why)
            if key in seen:
                continue
            seen.add(key)
            print('  %s : %s' % (fp, why))

    if args.mode == 'restore':
        if not args.out:
            print('\n[错误] restore 模式必须给 --out', file=sys.stderr)
            return 1
        out_root = os.path.realpath(args.out)
        written = 0
        for rel, _ in rows:
            fp = [k for k in files if (os.path.relpath(os.path.realpath(k), root) == rel
                                       or k == rel)]
            if not fp:
                continue
            content = files[fp[0]]
            dst = os.path.join(out_root, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with open(dst, 'w', encoding='utf-8') as f:
                f.write(content)
            written += 1
        print('\n已写入 %d 个文件到 %s' % (written, out_root))
    return 0


if __name__ == '__main__':
    sys.exit(main())
