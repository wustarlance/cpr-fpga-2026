#!/usr/bin/env python3
"""Compile project RTL, require a self-check PASS, and retain Icarus evidence."""
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

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
RTL, TB = "project/rtl/", "tests/sim/tb/"
TESTS = {
    "tb_adc_ctrl": {"sources": [RTL + "adc_ctrl.v", "tests/sim/stubs/eg_phy_adc_timing_model.v", TB + "tb_adc_ctrl.v"]},
    "tb_pressure_normalize": {"sources": [RTL + "pressure_normalize.v", TB + "tb_pressure_normalize.v"]},
    "tb_peak_detect": {"sources": [RTL + "peak_detect.v", TB + "tb_peak_detect.v"]},
    "tb_sample_mailbox": {"sources": [RTL + "sample_mailbox.v", TB + "tb_sample_mailbox.v"]},
    "tb_cpr_sensor_path": {"sources": [RTL + n + ".v" for n in ("adc_ctrl", "sample_mailbox", "pressure_normalize", "peak_detect", "cpr_sensor_path")] + ["tests/sim/stubs/eg_phy_adc_timing_model.v", TB + "tb_cpr_sensor_path.v"]},
    "tb_training_events": {"sources": [RTL + "training_core.v", TB + "tb_training_events.v"]},
    "tb_video_rgb_to_axis": {"sources": [RTL + "video_rgb_to_axis_640x480.v", TB + "tb_video_rgb_to_axis.v"]},
    "tb_training_core": {
        "sources": [RTL + "training_core.v", TB + "tb_training_core.v"],
        "pass_pattern": r"(?m)^PASS: (?:tb_training_core\b|training core behavior\b)"},
    "tb_cpr_control": {
        "sources": [RTL + n + ".v" for n in ("timebase", "input_filter", "training_core", "rate_display_lut", "cpr_control")] + [TB + "tb_cpr_control.v"],
        "pass_pattern": r"(?m)^PASS: (?:tb_cpr_control\b|cpr_control integration test\b)"},
    "tb_rate_display_lut": {
        "sources": [RTL + "rate_display_lut.v", TB + "tb_rate_display_lut.v"],
        "pass_pattern": r"(?m)^PASS: (?:tb_rate_display_lut\b|rate_display_lut exhaustive range test\b)"},
    "tb_brightness_rgb": {"sources": [RTL + "brightness_rgb.v", TB + "tb_brightness_rgb.v"]},
    "tb_bmp_scan": {"sources": ["project/vendor/SD/bmp_read.v", TB + "tb_bmp_scan.v"], "pass_pattern": r"(?m)^\[PASS\] BMP scanner/load regression complete"},
    "tb_sdram_refresh": {"sources": [TB + "tb_sdram_refresh.v"], "include_dirs": ["project/vendor/include"], "pass_pattern": r"(?m)^\[PASS\]"},
    "tb_frame_buffer_publish": {"sources": [RTL + "frame_buffer_publish.v", "project/vendor/SD/frame_fifo_read.v", TB + "tb_frame_buffer_publish.v"]},
    "tb_sd_buffer_ownership": {"sources": [RTL + "frame_buffer_publish.v", RTL + "SD/sd_card_bmp.v", "tests/sim/stubs/sd_image_reader_model.v", TB + "tb_sd_buffer_ownership.v"]},
    "tb_cpr_overlay": {"sources": [RTL + "cpr_overlay.v", TB + "tb_cpr_overlay.v"]},
    "tb_reset_release": {"sources": [RTL + "reset_release.v", TB + "tb_reset_release.v"]},
}
TESTS["tb_sd_cache_ownership"] = {"sources": [RTL + "cpr_page_manager.v", RTL + "frame_buffer_publish.v", RTL + "SD/sd_card_bmp.v", "tests/sim/stubs/sd_cache_reader_model.v", TB + "tb_sd_cache_ownership.v"]}
TESTS["tb_audio_tone"] = {"sources": [RTL + "cpr_audio_tone_i2s.v", TB + "tb_audio_tone.v"],
                          "pass_pattern": r"(?m)^PASS: 8-note scale"}
TESTS["tb_bmp_scaled"] = {"sources": ["project/vendor/SD/bmp_read_scaled.v", TB + "tb_bmp_scaled.v"]}
TESTS["tb_bmp_scaled_frame"] = {"sources": ["project/vendor/SD/bmp_read_scaled.v", TB + "tb_bmp_scaled.v"]}
TESTS["tb_sd_scaled_pipeline"] = {"sources": [RTL + "cpr_page_manager.v", RTL + "SD/sd_card_bmp.v", RTL + "frame_buffer_publish.v", "project/vendor/SD/bmp_read_scaled.v", "project/vendor/SD/frame_read_write.v", "project/vendor/SD/frame_fifo_write.v", "project/vendor/SD/frame_fifo_read.v", TB + "tb_sd_scaled_pipeline.v"]}
TESTS.update({
    "tb_contrast_rgb": {"sources": [RTL + "contrast_rgb.v", TB + "tb_contrast_rgb.v"], "plusargs": ["+golden=fixtures/contrast_golden.mem"], "pass_pattern": r"(?m)^PASS: contrast_rgb\b"},
    "tb_font5x7_rom": {"sources": [RTL + "font5x7_rom.v", TB + "tb_font5x7_rom.v"], "plusargs": ["+glyph=fixtures/glyph5x7_golden.mem"], "pass_pattern": r"(?m)^PASS: font5x7_rom\b"},
    "tb_scroll_contract": {"sources": [RTL + "scroll_text.v", RTL + "font5x7_rom.v", TB + "tb_scroll_contract.v"]},
    "tb_contrast_controls": {"sources": [RTL + "input_filter.v", RTL + "contrast_controls.v", TB + "tb_contrast_controls.v"]},
    "tb_cpr_overlay_features": {"sources": [RTL + "cpr_overlay.v", RTL + "scroll_text.v", RTL + "font5x7_rom.v", RTL + "cpr_subtitle_rom.v", TB + "tb_cpr_overlay_features.v"]},
})
TESTS["tb_contrast_rgb"]["fixtures"] = ["tests/sim/fixtures/contrast_golden.mem"]
TESTS["tb_font5x7_rom"]["fixtures"] = ["tests/sim/fixtures/glyph5x7_golden.mem"]
TESTS["tb_scroll_contract"]["fixtures"] = ["tests/sim/fixtures/scroll_text_ascii.mem", "tests/sim/fixtures/glyph5x7_golden.mem"]
TESTS["tb_cpr_overlay"]["sources"] += [RTL + "scroll_text.v", RTL + "font5x7_rom.v", RTL + "cpr_subtitle_rom.v"]
TESTS["tb_training_layout"] = {
    "sources": [RTL + "cpr_overlay.v", RTL + "scroll_text.v", RTL + "font5x7_rom.v", RTL + "cpr_subtitle_rom.v", TB + "tb_training_layout.v"],
    "fixtures": ["tests/sim/fixtures/training_panel_golden.mem", "tests/sim/fixtures/glyph5x7_golden.mem"],
}
TESTS.update({'tb_sd_cmd_recovery': {'sources': ['project/vendor/SD/sd_card_cmd.v', 'tests/sim/tb/tb_sd_cmd_recovery.v'], 'fixtures': ['tests/sim/fixtures/sd_crc_sector.mem'], 'plusargs': []}, 'tb_sd_sector_recovery': {'sources': ['project/vendor/SD/sd_card_sec_read_write.v', 'tests/sim/tb/tb_sd_sector_recovery.v']}, 'tb_sd_image_recovery': {'sources': ['project/rtl/SD/sd_card_bmp.v', 'project/vendor/SD/bmp_read.v', 'project/rtl/frame_buffer_publish.v', 'project/vendor/SD/frame_fifo_write.v', 'tests/sim/stubs/sd_fault_sector_model.v', 'tests/sim/tb/tb_sd_image_recovery.v']}, 'tb_sd_retry_limits': {'sources': ['project/rtl/SD/sd_card_bmp.v', 'project/vendor/SD/bmp_read.v', 'tests/sim/stubs/sd_fault_sector_model.v', 'tests/sim/tb/tb_sd_retry_limits.v']}})
for name in ("tb_sd_buffer_ownership", "tb_sd_image_recovery", "tb_sd_retry_limits"):
    TESTS[name]["sources"].insert(0, RTL + "cpr_page_manager.v")
TESTS["tb_page_manager"] = {"sources": [RTL + "cpr_page_manager.v", TB + "tb_page_manager.v"]}
TESTS["tb_page_status"] = {"sources": [RTL + "sample_mailbox.v", RTL + "page_status_cdc.v", RTL + "cpr_overlay.v", RTL + "scroll_text.v", RTL + "font5x7_rom.v", RTL + "cpr_subtitle_rom.v", TB + "tb_page_status.v"]}
TESTS["tb_training_pages"] = {"sources": [RTL + "cpr_page_manager.v"] + [s for s in TESTS["tb_sd_image_recovery"]["sources"] if s != RTL + "cpr_page_manager.v" and s != TB + "tb_sd_image_recovery.v"] + [TB + "tb_training_pages.v"]}
TESTS["tb_sd_scaled_pages"] = {"sources": [RTL + "cpr_page_manager.v", RTL + "SD/sd_card_bmp.v", "project/vendor/SD/bmp_read_scaled.v", RTL + "frame_buffer_publish.v", "project/vendor/SD/frame_fifo_write.v", "tests/sim/stubs/sd_fault_sector_model.v", TB + "tb_sd_scaled_pages.v"]}
TESTS["tb_sd_scaled_recovery"] = {"sources": TESTS["tb_sd_scaled_pages"]["sources"][:-1] + [TB + "tb_sd_scaled_recovery.v"]}
ZH = [RTL + "cpr_font16_rom.v", RTL + "cpr_zh_strings.v", RTL + "cpr_text_zh.v"]
TESTS["tb_chinese_rom"] = {
    "sources": ZH[:2] + [TB + "tb_chinese_rom.v"],
    "fixtures": ["tests/sim/fixtures/chinese_glyphs.mem", "tests/sim/fixtures/chinese_messages.mem"],
}
TESTS["tb_chinese_scroll"] = {
    "sources": ZH + [TB + "tb_chinese_scroll.v"],
    "fixtures": ["tests/sim/fixtures/chinese_glyphs.mem", "tests/sim/fixtures/chinese_messages.mem"],
}
TESTS["tb_chinese_overlay"] = {
    "sources": TESTS["tb_training_layout"]["sources"][:-1] + ZH + [TB + "tb_chinese_overlay.v"],
    "fixtures": ["tests/sim/fixtures/chinese_glyphs.mem", "tests/sim/fixtures/chinese_screen_cells.mem",
                 "project/assets/tutorials/bmp_training_safe/02_compressions.bmp"],
}

FAIL_PATTERN = re.compile(r"\b(?:FAIL|FATAL|TIMEOUT)\b", re.IGNORECASE)


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def locate_tool(value, name):
    candidate = Path(value).expanduser() if value else None
    if candidate is None or not candidate.is_file():
        found = shutil.which(value or name)
        portable = REPO.parent.parent / "work/iverilog-portable/ucrt64/bin" / (name + (".exe" if os.name == "nt" else ""))
        if found:
            candidate = Path(found)
        elif not value and portable.is_file():
            candidate = portable
        else:
            raise ValueError(f"Cannot find {name}; install Icarus or supply --{name}.")
    return candidate.resolve()


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
        output = decode(error.stdout) + decode(error.stderr) + "\nRUNNER TIMEOUT\n"
        record = {"command": command, "returncode": None, "timed_out": True}
    except OSError as error:
        output = f"RUNNER ERROR: {error}\n"
        record = {"command": command, "returncode": None, "timed_out": False, "launch_error": str(error)}
    log.write_text(output, encoding="utf-8")
    record.update(elapsed_seconds=round(time.monotonic() - started, 6), log=str(log))
    return record, output


def run_test(name, config, output, compiler, runtime, env, timeout):
    record = {"test": name, "top": config.get("top", name), "status": "failed"}
    directory = output / name
    directory.mkdir()
    try:
        if not isinstance(config.get("sources"), list) or not config["sources"]:
            raise ValueError("Test manifest must have a nonempty sources list")
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", record["top"]):
            raise ValueError("Test top must be a Verilog identifier")
        sources = [(REPO / source).resolve() for source in config["sources"]]
        missing = [str(source) for source in sources if not source.is_file()]
        if missing:
            record["error"] = "Missing sources: " + ", ".join(missing)
            return record
        record["sources"] = [{"path": str(source), "sha256": sha256(source)} for source in sources]
        fixtures = [(REPO / value).resolve() for value in config.get("fixtures", [])]
        if any(not value.is_file() for value in fixtures):
            raise ValueError("Missing verification fixture")
        record["fixtures"] = [{"path": str(value), "sha256": sha256(value)} for value in fixtures]
        pattern = config.get("pass_pattern", rf"(?m)^PASS:? {re.escape(name)}(?:\s|:|$)")
        re.compile(pattern)
        record["pass_pattern"] = pattern
        image = directory / (name + ".vvp")
        include_args = ["-I" + str((REPO / directory).resolve()) for directory in config.get("include_dirs", [])]
        command = compiler + ["-g2012", "-Wall", "-s", record["top"], "-o", str(image)] + include_args + list(map(str, sources))
        record["compile"], _ = invoke(command, HERE, env, timeout, directory / "compile.log")
        if record["compile"]["timed_out"] or record["compile"]["returncode"] != 0 or not image.is_file():
            record["error"] = "Compilation failed or timed out"
            return record
        record["compiled_image_sha256"] = sha256(image)
        record["run"], text = invoke(runtime + [str(image)] + config.get("plusargs", []), HERE, env, timeout, directory / "run.log")
        record["pass_marker_seen"] = re.search(pattern, text) is not None
        record["failure_marker_seen"] = FAIL_PATTERN.search(text) is not None
        if record["run"]["timed_out"]:
            record["error"] = "Simulation timed out"
        elif record["run"]["returncode"] != 0:
            record["error"] = "Simulation returned nonzero or failed to launch"
        elif record["failure_marker_seen"]:
            record["error"] = "Simulation printed a failure marker"
        elif not record["pass_marker_seen"]:
            record["error"] = "Missing required PASS marker; an empty run is not a pass"
        elif any(sha256(value) != entry["sha256"] for value, entry in zip(fixtures, record["fixtures"])):
            record["error"] = "Fixture changed during simulation"
        elif any(sha256(source) != entry["sha256"] for source, entry in zip(sources, record["sources"])):
            record["error"] = "Source changed during simulation"
        else:
            record["status"] = "passed"
        return record
    except (OSError, ValueError, TypeError, KeyError, re.error) as error:
        record["error"] = str(error)
        return record
    finally:
        (directory / "result.json").write_text(json.dumps(record, indent=2), encoding="utf-8")


def runner_controls(output, compiler, runtime, env):
    fixtures = {
        "runner_good": ('$display("PASS: runner_good"); $finish;', True),
        "runner_empty": ("$finish;", False),
        "runner_fatal": ('$display("PASS: runner_fatal"); $fatal(1, "deliberate fatal");', False),
        "runner_fail_marker": ('$display("PASS: runner_fail_marker"); $display("FAIL deliberate"); $finish;', False),
        "runner_timeout": ("forever #1;", False),
    }
    directory = output / "runner-control-sources"
    directory.mkdir()
    records = []
    for name, (body, expected_pass) in fixtures.items():
        source = directory / (name + ".v")
        source.write_text(f"module {name}; initial begin {body} end endmodule\n", encoding="utf-8")
        record = run_test(name, {"sources": [str(source)]}, output, compiler, runtime, env, 0.5)
        record["expected_pass"] = expected_pass
        record["control_succeeded"] = (record["status"] == "passed") == expected_pass
        if not expected_pass and record.get("compile", {}).get("returncode") != 0:
            record["control_succeeded"] = False
        records.append(record)
        print(f"CONTROL {name}: {'PASS' if record['control_succeeded'] else 'FAIL'}")
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tests", nargs="*", help="manifest test names; default is --all")
    parser.add_argument("--all", action="store_true", help="all registered tests; missing sources fail")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--iverilog", default=os.environ.get("IVERILOG"))
    parser.add_argument("--vvp", default=os.environ.get("VVP"))
    parser.add_argument("--ivl-dir", type=Path, help="portable compiler backend/VPI directory")
    # Chinese raster checks compare 2,457,600 demo/ADC pixels across four
    # complete frames. Keep a finite bound that covers this larger test.
    parser.add_argument("--timeout", type=float, default=240.0, help="seconds per compile/run")
    parser.add_argument("--output", type=Path, help="new or empty evidence directory")
    parser.add_argument("--manifest", type=Path, help="JSON tests/sources/top/pass_pattern; paths relative to repo")
    parser.add_argument("--self-test-runner", action="store_true")
    args = parser.parse_args()
    try:
        tests = json.loads(args.manifest.read_text(encoding="utf-8")) if args.manifest else TESTS
        if not isinstance(tests, dict) or not tests:
            raise ValueError("Manifest must contain at least one test")
        if args.list:
            print("\n".join(tests))
            return 0
        if args.timeout <= 0:
            raise ValueError("--timeout must be positive")
        selected = list(tests) if args.all or not args.tests else args.tests
        if len(set(selected)) != len(selected):
            raise ValueError("Duplicate test names are not allowed")
        for name in selected:
            if name not in tests or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
                raise ValueError(f"Unknown/invalid test name: {name}; use --list")
        iverilog, vvp = locate_tool(args.iverilog, "iverilog"), locate_tool(args.vvp, "vvp")
        env = dict(os.environ)
        env["PATH"] = os.pathsep.join([str(iverilog.parent), str(vvp.parent), env.get("PATH", "")])
        backend = args.ivl_dir
        guessed = iverilog.parent.parent / "lib/ivl"
        if backend is None and guessed.is_dir():
            backend = guessed
        compiler, runtime = [str(iverilog)], [str(vvp)]
        if backend is not None:
            backend = backend.resolve()
            if not backend.is_dir():
                raise ValueError(f"Missing Icarus backend directory: {backend}")
            compiler += ["-B", str(backend)]
            runtime += ["-M", str(backend)]
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
        output = (args.output or (HERE / "build" / stamp)).resolve()
        if output.exists() and any(output.iterdir()):
            raise ValueError(f"Evidence directory must be new or empty: {output}")
        output.mkdir(parents=True, exist_ok=True)
        (HERE / "waves").mkdir(exist_ok=True)
        summary = {"schema_version": 1, "started_utc": stamp, "repository": str(REPO),
                   "runner_sha256": sha256(__file__), "timeout_seconds": args.timeout,
                   "verification_stage": "RTL functional simulation only", "tools": {}, "tests": []}
        for name, prefix, binary in (("iverilog", compiler, iverilog), ("vvp", runtime, vvp)):
            version, text = invoke(prefix + ["-V"], HERE, env, args.timeout, output / (name + ".version.log"))
            summary["tools"][name] = {"path": str(binary), "sha256": sha256(binary),
                                      "version": text.splitlines()[0] if text else "",
                                      "version_returncode": version["returncode"]}
            if version["timed_out"] or version["returncode"] != 0:
                raise ValueError(f"{name} version check failed; see {version['log']}")
        for name in selected:
            record = run_test(name, tests[name], output, compiler, runtime, env, args.timeout)
            summary["tests"].append(record)
            print(f"{'PASS' if record['status'] == 'passed' else 'FAIL'} {name}: " + record.get("error", "compiled product RTL and matched self-check PASS"))
        if args.self_test_runner:
            summary["runner_controls"] = runner_controls(output, compiler, runtime, env)
        passed = all(t["status"] == "passed" for t in summary["tests"])
        passed = passed and all(t["control_succeeded"] for t in summary.get("runner_controls", []))
        summary.update(status="passed" if passed else "failed", completed_utc=dt.datetime.now(dt.timezone.utc).isoformat())
        (output / "results.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
        print(f"Evidence: {output}")
        return 0 if passed else 1
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
