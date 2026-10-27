#!/usr/bin/env python3
"""布局布线后仿真（门级网表 + SDF 反标）跑整片冒烟测试。

前置：先用 TD 从已布线的 route.db 导出网表和 SDF（不重跑 P&R）

    cd project
    CPR_TOP=top /d/ANLU/TD_6.2.1/bin/td_commands_prompt.exe scripts/postsim/export.tcl

用法（仓库根目录）：

    python tests/sim/postsim/run_postsim.py --top top
    python tests/sim/postsim/run_postsim.py --top top --top top_adc

产物落在 tests/sim/build_msim/<UTC 时间戳>/<top>_postsim/：
vlog.log / vsim.log / results.json。用完可以整个目录删掉，
结论写进 project/docs/ 的报告里。

两个必须知道的仿真前提（细节见 project/docs/timing-postsim-20261026.md）：

1. TD 的 EG_PHY_PLL 功能模型只出 clkc，extlock 恒 0。设计的
   por_reset_n = rst_n && all_plls_locked，所以纯仿真里整片被永久复位。
   测试平台在复位释放那一拍把 all_plls_locked 强制为 1——这是对厂商模型的
   补丁，不是改设计。
2. TD 的 EG4 单元模型只有部分 specify 块，SDF 里有几千条 SETUPHOLD/IOPATH
   对不上，ModelSim 会按 fatal 处理。用 -sdfnoerror 降级为 warning，
   并用 +notimingchecks 关掉时序检查（延时照常反标，只是不报违例）。
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent          # tests/sim/postsim
REPO = HERE.parents[2]                          # 仓库根
PROJECT = REPO / "project"

# TD 的 EG4 功能模型库。common 是映射层（LUT/加法器/时序单元），
# eg4 是器件层（slice/pad/BRAM/PLL/SDRAM 硬核）。al_phy_glbl.v 和
# eg_phy_glbl.v 都定义 glbl，只能编译任意一个，否则 glbl 重复定义。
SIM_LIB_COMMON = ["al_logic_debughub.v", "al_map_adder.v", "al_map_alu2b.v",
                  "al_map_basic.v", "al_map_lut.v", "al_map_mult.v",
                  "al_map_mux4.v", "al_map_seq.v"]

# 整片后仿真的时长（ns）。门级 + SDF 实测约 0.7~1.0 us/s，这组参数约 10 分钟。
T_RESET = 100_000
T_SETTLE = 400_000
T_WATCH = 150_000


def locate_modelsim(value):
    if value:
        directory = Path(value).expanduser()
        if not directory.is_dir():
            raise ValueError(f"ModelSim directory not found: {directory}")
        return directory.resolve()
    found = shutil.which("vlog")
    if found:
        return Path(found).parent.resolve()
    raise ValueError("Cannot find vlog; pass --modelsim \"D:/Program Files/Mentor Graphics ModelSim SE-64 10.6e/win64\".")


def sim_library(td_root):
    release = Path(td_root) / "sim_release"
    common = [release / "common" / name for name in SIM_LIB_COMMON]
    eg4 = sorted((release / "eg4").glob("*.v"))
    if not common[0].is_file() or not eg4:
        raise ValueError(f"TD simulation library not found under {release}")
    return common + eg4


def windows_path(path):
    return str(Path(path).resolve()).replace("\\", "/")


def invoke(command, cwd, env, timeout, log):
    with open(log, "w", encoding="utf-8", errors="replace") as handle:
        result = subprocess.run(command, cwd=str(cwd), env=env, stdout=handle,
                                stderr=subprocess.STDOUT, timeout=timeout)
    return result.returncode, Path(log).read_text(encoding="utf-8", errors="replace")


def run_top(top, modelsim, td_root, output, timeout):
    netlist = PROJECT / "build" / top / "simulation" / f"{top}_sim.v"
    sdf = PROJECT / "build" / top / "simulation" / f"{top}.sdf"
    if not netlist.is_file() or not sdf.is_file():
        raise ValueError(f"missing gate-level netlist or SDF for {top}; run scripts/postsim/export.tcl first")

    record = {"top": top, "status": "failed",
              "netlist": str(netlist.relative_to(REPO)),
              "netlist_bytes": netlist.stat().st_size,
              "sdf": str(sdf.relative_to(REPO)),
              "sdf_bytes": sdf.stat().st_size,
              "sdf_mode": "max (setup corner)",
              "duration_ns": {"reset": T_RESET, "settle": T_SETTLE, "watch": T_WATCH}}

    work = output / f"{top}_postsim"
    work.mkdir(parents=True, exist_ok=True)
    library = work / "work"
    vlib, vlog, vsim = (modelsim / name for name in ("vlib.exe", "vlog.exe", "vsim.exe"))

    code, text = invoke([str(vlib), str(library)], work, os.environ, timeout, work / "vlib.log")
    if code != 0:
        record["error"] = "vlib failed"
        return record

    sources = [str(p) for p in sim_library(td_root)]
    sources += [windows_path(netlist), windows_path(HERE / "tb_top_postsim.v")]
    command = [str(vlog), "-work", str(library)]
    if top == "top_adc":
        # 两个顶层的网表模块名不同、端口一致，测试平台用宏选模块名。
        command.append("+define+POSTSIM_TOP_ADC")
    command += sources
    code, text = invoke(command, work, os.environ, timeout, work / "vlog.log")
    record["compile_errors"] = len(re.findall(r"(?m)^\*\* Error", text))
    if code != 0 or record["compile_errors"]:
        record["error"] = "compile failed; see vlog.log"
        return record

    command = [str(vsim), "-c", "-work", str(library), "tb_top_postsim", "glbl",
               "-sdfmax", f"/tb_top_postsim/dut={windows_path(sdf)}",
               "-sdfnoerror", "-sdfnowarn",
               "-suppress", "3722", "-suppress", "3017", "-suppress", "8756",
               "+notimingchecks",
               "-do", "run -all; quit -f",
               f"+T_RESET={T_RESET}", f"+T_SETTLE={T_SETTLE}", f"+T_WATCH={T_WATCH}"]
    code, text = invoke(command, work, os.environ, timeout, work / "vsim.log")

    info = [line.strip() for line in text.splitlines() if re.search(r"\bINFO:", line)]
    record["log"] = info
    record["fatal"] = bool(re.search(r"(?m)^\*\* (?:Fatal|Error)", text))
    record["sdf_loaded"] = "Loading timing data from" in text
    if "PASS: top_postsim" in text and not record["fatal"]:
        record["status"] = "passed"
    else:
        failures = [line.strip() for line in text.splitlines() if re.search(r"\bFAIL:", line)]
        record["failures"] = failures
        record["error"] = "post-simulation self-check failed; see vsim.log"
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--top", action="append", default=None,
                        help="top name (top / top_adc); repeatable")
    parser.add_argument("--modelsim", help="ModelSim win64 directory containing vlog/vsim")
    parser.add_argument("--td", default=os.environ.get("TD_ROOT", "D:/ANLU/TD_6.2.1"),
                        help="TD installation root (default D:/ANLU/TD_6.2.1)")
    parser.add_argument("--timeout", type=float, default=3600.0)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    tops = args.top or ["top"]
    modelsim = locate_modelsim(args.modelsim)
    env_license = modelsim / "LICENSE.TXT"
    if not any(key in os.environ for key in ("LM_LICENSE_FILE", "MGLS_LICENSE_FILE")) and env_license.is_file():
        os.environ["LM_LICENSE_FILE"] = str(env_license)

    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    output = (args.output or (HERE.parent / "build_msim" / stamp)).resolve()
    if output.exists() and any(output.iterdir()):
        raise ValueError("output directory must be new or empty")
    output.mkdir(parents=True, exist_ok=True)

    summary = {"schema_version": 1, "started_utc": stamp, "modelsim": str(modelsim),
               "stage": "post-route gate-level simulation with SDF annotation",
               "results": []}
    exit_code = 0
    for top in tops:
        record = run_top(top, modelsim, args.td, output, args.timeout)
        summary["results"].append(record)
        print(f"{top}: {record['status']}"
              + (f" — {record.get('error')}" if record.get("error") else ""))
        if record["status"] != "passed":
            exit_code = 1
    (output / "results.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
                                         encoding="utf-8")
    print(f"evidence: {output}")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
