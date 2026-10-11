#!/usr/bin/env python3
"""Run TD synthesis for both CPR tops and retain revision-specific evidence."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

PROJECT = Path(__file__).resolve().parent
REPO = PROJECT.parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_hashes():
    # Include generated HDL and plain-text includes beside registered IPCs.
    # This conservative inventory includes the reference source forest,
    # rather than claiming that every file in it is an active design input.
    suffixes = {".v", ".sv", ".vhd", ".ipc", ".tcl", ".sdc", ".adc", ".al", ".mif", ".hex", ".mem"}
    records = {}
    for root in (PROJECT, REPO / "05_lab_ex/lab_ex5_i2s/src"):
        if not root.is_dir():
            raise ValueError(f"Required source directory missing: {root}")
        for path in root.rglob("*"):
            relative = path.relative_to(REPO)
            if any(p == "build" or p.endswith("_Runs") for p in relative.parts):
                continue
            if path.is_file() and path.suffix.lower() in suffixes:
                records[relative.as_posix()] = digest(path)
    return dict(sorted(records.items()))


def summarize(log, top):
    diagnostics = [line.strip() for line in log.splitlines()
                   if re.search(r"\b(?:WARNING|ERROR|FATAL)\b", line)]
    mailbox = []
    for match in re.finditer(r"^CPR_MAILBOX_REGS hold=(.*?) capture=(.*?)$", log, re.M):
        mailbox.append({"hold_bits": len(re.findall(r"\{[^{}]+\}", match[1])),
                        "capture_bits": len(re.findall(r"\{[^{}]+\}", match[2]))})
    errors = [line for line in diagnostics if re.search(r"\b(?:ERROR|FATAL)\b|CRITICAL-WARNING", line)]
    version = re.search(r"Tang Dynasty, V([^\s]+)", log)
    return {"td_version": version[1] if version else None,
            "pass_marker": f"CPR_SYNTHESIS_PASS {top}" in log,
            "diagnostics": diagnostics, "errors_or_critical_warnings": errors,
            "mailbox_collections": mailbox}


def run_top(tool, top, output, timeout):
    destination = output / top
    destination.mkdir()
    env = dict(os.environ, CPR_TOP=top)
    command = [str(tool), "build.tcl"]
    started = time.monotonic()
    timed_out = False
    code = None
    try:
        proc = subprocess.run(command, cwd=PROJECT, env=env, capture_output=True,
                              timeout=timeout)
        code = proc.returncode
        raw = proc.stdout + proc.stderr
    except subprocess.TimeoutExpired as error:
        raw = (error.stdout or b"") + (error.stderr or b"") + b"\nVERIFY_TIMEOUT\n"
        timed_out = True
    except OSError as error:
        raw = str(error).encode("utf-8")
    (destination / "td.log").write_bytes(raw)
    log = raw.decode("utf-8", errors="replace")
    record = {"top": top, "command": command, "returncode": code,
              "timed_out": timed_out, "elapsed_seconds": round(time.monotonic() - started, 3),
              **summarize(log, top)}
    resources = {}
    reports_fresh = record["pass_marker"] and code == 0 and not timed_out
    for name in ("rtl_area.rpt", "gate_area.rpt"):
        report = PROJECT / "build" / top / name
        if reports_fresh and report.is_file():
            shutil.copy2(report, destination / name)
            if name == "gate_area.rpt":
                for kind, used, available, percent in re.findall(
                        r"^#(lut|reg|bram|adc|pll)\s+(\d+)\s+out of\s+(\d+)\s+([\d.]+)%", report.read_text(), re.M):
                    resources[kind] = {"used": int(used), "available": int(available), "percent": float(percent)}
    # TD omits the ADC utilization row when this resource is unused. The
    # board-demo top deliberately has no ADC; do not reject that valid report.
    if top == "top" and "adc" not in resources:
        resources["adc"] = {"used": 0, "available": 1, "percent": 0.0,
                            "report_row_omitted": True}
    record["resources"] = resources
    record["reports"] = {p.name: digest(p) for p in destination.glob("*.rpt")}
    mailbox_ok = top != "top_adc" or (record["mailbox_collections"] and all(
        x["hold_bits"] == 12 and x["capture_bits"] == 12 for x in record["mailbox_collections"]))
    expected_adc = 1 if top == "top_adc" else 0
    resources_ok = (set(resources) == {"lut", "reg", "bram", "adc", "pll"}
                    and resources["lut"]["available"] == 19600
                    and resources["adc"]["used"] == expected_adc
                    and all(v["used"] <= v["available"] for v in resources.values()))
    record["status"] = "passed" if (reports_fresh and not record["errors_or_critical_warnings"]
        and record["td_version"] and len(record["reports"]) == 2 and mailbox_ok and resources_ok) else "failed"
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--td", help="TD CLI executable, such as td_commands_prompt.exe")
    parser.add_argument("--tops", nargs="+", choices=("top", "top_adc"), default=["top", "top_adc"])
    parser.add_argument("--timeout", type=float, default=600)
    args = parser.parse_args()
    executable = args.td or shutil.which("td_commands_prompt.exe") or shutil.which("td")
    if not executable or not Path(executable).is_file() or args.timeout <= 0:
        parser.error("Supply an existing TD executable with --td and a positive timeout")
    tool = Path(executable).resolve()
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    output = PROJECT / "build" / ("verify_" + stamp)
    output.mkdir(parents=True)
    result = {"device": "EG4S20BG256", "stage": "RTL and gate synthesis only",
              "tool": str(tool), "tool_sha256": digest(tool),
              "runner_sha256": digest(Path(__file__)), "results": []}
    try:
        before = source_hashes()
        result["source_inventory_scope"] = "project inputs and lab_ex5_i2s source forest, including inactive reference files"
        result["sources"] = before
        for top in dict.fromkeys(args.tops):
            print(f"TD synthesis: {top}", flush=True)
            record = run_top(tool, top, output, args.timeout)
            result["results"].append(record)
            print(f"{top}: {record['status']} ({record['elapsed_seconds']} s)", flush=True)
        result["sources_unchanged"] = before == source_hashes()
        result["tool_unchanged"] = result["tool_sha256"] == digest(tool)
        result["status"] = "passed" if (result["sources_unchanged"] and result["tool_unchanged"]
            and all(r["status"] == "passed" for r in result["results"])) else "failed"
    except (OSError, ValueError) as error:
        result.update(status="failed", error=str(error))
    (output / "results.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Evidence: {output}")
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
