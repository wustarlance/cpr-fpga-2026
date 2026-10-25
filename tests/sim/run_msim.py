#!/usr/bin/env python3
"""Compile project RTL with ModelSim SE and require a self-check PASS.

ModelSim counterpart of run.py (which needs Icarus Verilog). The test list,
source lists and PASS patterns are imported from run.py so both runners stay
in sync. Evidence lands in tests/sim/build_msim/<UTC stamp>/.

Usage from the repository root:

    python tests/sim/run_msim.py --list
    python tests/sim/run_msim.py tb_adc_ctrl tb_peak_detect
    python tests/sim/run_msim.py --all

The simulator needs LM_LICENSE_FILE (or MGLS_LICENSE_FILE) to point at
ModelSim's win64/LICENSE.TXT. Override the tool directory with --modelsim.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
# Reuse the single source of truth for the test list.
MANIFEST = runpy.run_path(str(HERE / "run.py"), run_name="msim_manifest_import")
TESTS = MANIFEST["TESTS"]
FAIL_PATTERN = re.compile(r"\b(?:FAIL|FATAL|TIMEOUT)\b", re.IGNORECASE)


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def locate_modelsim(value):
    if value:
        directory = Path(value).expanduser()
        if not directory.is_dir():
            raise ValueError(f"ModelSim directory not found: {directory}")
        return directory.resolve()
    found = shutil.which("vlog")
    if found:
        return Path(found).parent.resolve()
    raise ValueError(
        "Cannot find vlog. Add ModelSim's win64 directory to PATH, "
        "or pass --modelsim \"D:/Program Files/Mentor Graphics ModelSim SE-64 10.6e/win64\".")


def invoke(command, cwd, env, timeout, log):
    started = time.monotonic()
    try:
        result = subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True,
                                encoding="utf-8", errors="replace", timeout=timeout)
        output = result.stdout + result.stderr
        record = {"command": command, "returncode": result.returncode, "timed_out": False}
    except subprocess.TimeoutExpired as error:
        def decode(value):
            return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else (value or "")
        output = decode(error.stdout) + decode(error.stderr) + "\nMODELSIM TIMEOUT\n"
        record = {"command": command, "returncode": None, "timed_out": True}
    except OSError as error:
        output = f"RUNNER ERROR: {error}\n"
        record = {"command": command, "returncode": None, "timed_out": False,
                  "launch_error": str(error)}
    Path(log).write_text(output, encoding="utf-8")
    record.update(elapsed_seconds=round(time.monotonic() - started, 6), log=str(log))
    return record, output


def normalize_transcript(text):
    """ModelSim's command-mode transcript prefixes every line with '# '.

    Strip that marker (and trailing carriage returns) so the PASS patterns
    imported from run.py keep matching exactly as they do under Icarus.
    """
    lines = []
    for line in text.replace("\r\n", "\n").split("\n"):
        stripped = line.lstrip()
        if stripped.startswith("# "):
            line = line.replace("# ", "", 1)
        elif stripped.startswith("#"):
            line = line.replace("#", "", 1)
        lines.append(line)
    return "\n".join(lines)


def run_test(name, config, output, vlog, vsim, env, timeout):
    record = {"test": name, "status": "failed"}
    directory = output / name
    directory.mkdir(parents=True, exist_ok=True)
    library = directory / "work"
    # Sources are repo relative; fixtures inside testbenches resolve against tests/sim.
    sources = [str((REPO / source).resolve()) for source in config["sources"]]
    missing = [source for source in sources if not Path(source).is_file()]
    if missing:
        record["error"] = "missing sources: " + ", ".join(missing)
        return record

    vlib, _ = invoke([str(vsim.parent / "vlib.exe"), str(library)], HERE, env, timeout,
                     directory / "vlib.log")
    if vlib["returncode"] != 0:
        record["error"] = "vlib failed; see vlib.log"
        return record

    command = [str(vlog), "-sv", "-work", str(library)]
    for include in config.get("include_dirs", []):
        command += ["+incdir+" + str((REPO / include).resolve())]
    command += sources
    compiled, text = invoke(command, HERE, env, timeout, directory / "vlog.log")
    record["compile"] = {key: compiled[key] for key in ("returncode", "timed_out", "log")}
    if compiled["returncode"] != 0 or compiled["timed_out"]:
        record["error"] = "compile failed; see vlog.log"
        return record

    top = config.get("top", name)
    command = [str(vsim), "-c", "-work", str(library), top]
    command += config.get("plusargs", [])
    command += ["-do", "run -all; quit -f"]
    # Tests read fixtures with paths relative to tests/sim.
    ran, text = invoke(command, HERE, env, timeout, directory / "vsim.log")
    record["run"] = {key: ran[key] for key in ("returncode", "timed_out", "log")}
    text = normalize_transcript(text)

    pattern = re.compile(config.get("pass_pattern", rf"(?m)^PASS:? {re.escape(name)}(?:\s|:|$)"))
    matched = bool(pattern.search(text))
    rejected = bool(FAIL_PATTERN.search(text))
    record.update(pass_matched=matched, fail_text=rejected)
    if ran["timed_out"]:
        record["error"] = "simulation timed out; see vsim.log"
    elif not matched:
        record["error"] = "no PASS text in vsim.log"
    elif rejected:
        record["error"] = "FAIL/FATAL text in vsim.log"
    else:
        record["status"] = "passed"
        record["error"] = "compiled product RTL and matched self-check PASS"
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tests", nargs="*", help="manifest test names; default is --all")
    parser.add_argument("--all", action="store_true", help="all registered tests")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--modelsim", help="ModelSim win64 directory containing vlog/vsim")
    parser.add_argument("--timeout", type=float, default=180.0,
                        help="seconds per compile and per run")
    parser.add_argument("--output", type=Path, help="new or empty evidence directory")
    args = parser.parse_args()
    try:
        if args.list:
            print("\n".join(TESTS))
            return 0
        if args.timeout <= 0:
            raise ValueError("--timeout must be positive")
        selected = list(TESTS) if args.all or not args.tests else args.tests
        if len(set(selected)) != len(selected):
            raise ValueError("Duplicate test names are not allowed")
        for name in selected:
            if name not in TESTS or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
                raise ValueError(f"Unknown/invalid test name: {name}; use --list.")
        modelsim = locate_modelsim(args.modelsim)
        vlog, vsim = modelsim / "vlog.exe", modelsim / "vsim.exe"
        for binary in (vlog, vsim):
            if not binary.is_file():
                raise ValueError(f"Missing simulator executable: {binary}")
        env = dict(os.environ)
        if not any(key in env for key in ("LM_LICENSE_FILE", "MGLS_LICENSE_FILE")):
            # Fall back to the license file shipped next to the simulator so a
            # fresh shell works without manual environment setup.
            bundled = modelsim / "LICENSE.TXT"
            if bundled.is_file():
                env["LM_LICENSE_FILE"] = str(bundled)
            else:
                print("WARNING: LM_LICENSE_FILE/MGLS_LICENSE_FILE is not set and no "
                      "LICENSE.TXT was found next to vlog; vsim may refuse to start.",
                      file=sys.stderr)

        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
        output = (args.output or (HERE / "build_msim" / stamp)).resolve()
        if output.exists() and any(output.iterdir()):
            raise ValueError("Evidence directory must be new or empty")
        output.mkdir(parents=True, exist_ok=True)

        summary = {"schema_version": 1, "started_utc": stamp, "repository": str(REPO),
                   "runner_sha256": sha256(__file__), "timeout_seconds": args.timeout,
                   "verification_stage": "RTL functional simulation only (ModelSim SE)",
                   "tools": {}, "tests": []}
        for name, binary in (("vlog", vlog), ("vsim", vsim)):
            version, text = invoke([str(binary), "-version"], HERE, env, args.timeout,
                                   output / (name + ".version.log"))
            summary["tools"][name] = {"path": str(binary), "sha256": sha256(binary),
                                      "version": text.splitlines()[0] if text else "",
                                      "version_returncode": version["returncode"]}
            if version["timed_out"] or version["returncode"] != 0:
                raise ValueError(f"{name} version check failed; see {version['log']}")

        for name in selected:
            record = run_test(name, TESTS[name], output, vlog, vsim, env, args.timeout)
            summary["tests"].append(record)
            print(f"{'PASS' if record['status'] == 'passed' else 'FAIL'} {name}: "
                  + record.get("error", ""))
        passed = all(t["status"] == "passed" for t in summary["tests"])
        summary.update(status="passed" if passed else "failed",
                       completed_utc=dt.datetime.now(dt.timezone.utc).isoformat())
        (output / "results.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
        print(f"Evidence: {output}")
        return 0 if passed else 1
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
