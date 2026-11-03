#!/usr/bin/env python3
"""从 project/project.al 生成 project/filelist.f（给 Verilator 用），或检查它是否过期。

为什么需要生成器
----------------
TD 的工程文件 project.al 才是"哪些源文件参与构建"的唯一真相（66 个 .v）。
lint 用的 filelist.f 必须和它同步，否则你新加了 rtl/xxx.v、lint 却还在检查旧清单，
会给出"通过"的假安全感。所以：

    python3 project/scripts/gen_filelist.py           # 重新生成
    python3 project/scripts/gen_filelist.py --check   # 只检查是否过期（lint 脚本会调它）

规则（与 build.tcl 的读取范围一致）
-----------------------------------
· 取 project.al 里所有 .v/.sv/.vh；
· 排除 *.enc.v（IEEE-1735 加密，Verilator 无法解析；TD 里正常使用）；
· 写入各 -I include 目录（vendor、vendor/SD、vendor/include、vendor/hdmi_lab 等），
  全部相对 project/，因为脚本会先 cd 到 project/ 再调用 Verilator。
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
AL = PROJECT / "project.al"
OUT = PROJECT / "filelist.f"

INCLUDES = [
    "-Irtl",
    "-Ivendor",
    "-Ivendor/SD",
    "-Ivendor/include",
    "-Ivendor/user_source/hdl_source/include",
    "-Ivendor/hdmi_lab/include",
]


def wanted() -> list[str]:
    if not AL.is_file():
        raise SystemExit(f"找不到 {AL}")
    files = re.findall(r'<File Path="([^"]+)"', AL.read_text(encoding="utf-8"))
    v = [f for f in files if f.endswith((".v", ".sv", ".vh"))]
    keep = [f for f in v if ".enc.v" not in f]
    if not keep:
        raise SystemExit("project.al 里没有可 lint 的 Verilog 源文件")
    return keep


def render(files: list[str]) -> str:
    return "\n".join(INCLUDES) + "\n" + "\n".join(files) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="只检查 filelist.f 是否与 project.al 一致")
    args = ap.parse_args()

    files = wanted()
    text = render(files)

    if args.check:
        if not OUT.is_file():
            print(f"[STALE] {OUT.name} 不存在，先跑: python3 project/scripts/gen_filelist.py")
            return 1
        current = OUT.read_text(encoding="utf-8")
        if current == text:
            print(f"[OK] filelist.f 与 project.al 一致（{len(files)} 个源文件）")
            return 0
        missing = [f for f in files if f not in current.split("\n")]
        extra = [l for l in current.split("\n")
                 if l and not l.startswith("-I") and l not in files]
        print("[STALE] filelist.f 与 project.al 不一致，先跑: "
              "python3 project/scripts/gen_filelist.py")
        for f in missing[:10]:
            print(f"   缺: {f}")
        for f in extra[:10]:
            print(f"   多: {f}")
        return 1

    OUT.write_text(text, encoding="utf-8")
    print(f"已生成 {OUT}（{len(INCLUDES)} 个 -I + {len(files)} 个源文件）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
