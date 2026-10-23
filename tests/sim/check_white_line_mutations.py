#!/usr/bin/env python3
"""Require the white-line regressions to reject three deliberate local faults."""
from pathlib import Path
import argparse, copy, importlib.util, json, os

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
spec = importlib.util.spec_from_file_location("white_line_sim_runner", HERE / "run.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--iverilog")
    ap.add_argument("--vvp")
    ap.add_argument("--ivl-dir", type=Path)
    ap.add_argument("--output", type=Path, required=True, help="new evidence directory")
    args = ap.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    sources = out / "mutation-sources"
    sources.mkdir()
    cc = runner.locate_tool(args.iverilog, "iverilog")
    vv = runner.locate_tool(args.vvp, "vvp")
    compiler, runtime = [str(cc)], [str(vv)]
    backend = args.ivl_dir or cc.parent.parent / "lib/ivl"
    if backend.is_dir():
        compiler += ["-B", str(backend.resolve())]
        runtime += ["-M", str(backend.resolve())]
    env = dict(os.environ)
    env["PATH"] = str(cc.parent) + os.pathsep + env.get("PATH", "")
    cases = [
        ("no_write_gap", "tb_frame_write_spacing", "project/vendor/SD/frame_fifo_write.v", "(restart_count==0) && ", "", "gap too short"),
        ("gate_active_refresh", "tb_frame_write_spacing", "project/vendor/SD/frame_fifo_write.v", "(burst_started || !Sdr_init_ref_vld)", "!Sdr_init_ref_vld", "broken burst 17"),
        ("bypass_read_alignment", "tb_frame_roundtrip", "tests/sim/tb/tb_frame_roundtrip.v", ".REGISTER_READ_DATA(1)", ".REGISTER_READ_DATA(0)", "pixel mismatch"),
    ]
    records = []
    for name, test, rel, old, new, reason in cases:
        text = (REPO / rel).read_text(encoding="utf-8")
        assert text.count(old) == 1, (rel, old)
        mutant = sources / (name + ".v")
        mutant.write_text(text.replace(old, new, 1), encoding="utf-8")
        cfg = copy.deepcopy(runner.TESTS[test])
        cfg.update(top=test, pass_pattern=rf"(?m)^PASS:? {test}\b")
        cfg["sources"] = [str(mutant) if value == rel else value for value in cfg["sources"]]
        result = runner.run_test(name, cfg, out, compiler, runtime, env, 90)
        log = out / name / "run.log"
        rejected = (result.get("compile", {}).get("returncode") == 0 and
                    result.get("run", {}).get("returncode") not in (0, None) and
                    log.is_file() and reason in log.read_text(encoding="utf-8"))
        result.update(expected_failure=reason, mutation_rejected=rejected)
        records.append(result)
        print(f"{'PASS' if rejected else 'FAIL'} controlled mutation {name}")
    passed = all(r["mutation_rejected"] for r in records)
    (out / "results.json").write_text(json.dumps({"status": "passed" if passed else "failed", "mutations": records}, indent=2) + "\n", encoding="utf-8")
    return 0 if passed else 1

if __name__ == "__main__":
    raise SystemExit(main())
