#!/usr/bin/env python3
"""Build the independent HX4S20C SDRAM diagnostic; never programs a device."""
from pathlib import Path
import argparse
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
PROJECT = REPO / "project"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_hashes():
    result = {}
    for root in (PROJECT, REPO / "project/vendor/hdmi_lab", HERE):
        for path in root.rglob("*"):
            rel = path.relative_to(REPO)
            if any(p == "build" or p.endswith("_Runs") for p in rel.parts):
                continue
            if path.is_file() and path.suffix.lower() in {
                ".v", ".sv", ".vhd", ".ipc", ".tcl", ".sdc", ".adc", ".al", ".mem", ".py"
            }:
                result[rel.as_posix()] = sha(path)
    return dict(sorted(result.items()))


def tcl_path(path):
    # Paths are local task paths. Braces and newlines cannot be represented here.
    s = path.resolve().as_posix()
    if any(c in s for c in "{}\r\n"):
        raise ValueError("Unsupported path characters")
    return "{" + s + "}"


def prepare(output, stage):
    project = (PROJECT / "project.al").read_text(encoding="utf-8")
    def absolute(match):
        from html import escape, unescape
        resolved = (PROJECT / unescape(match[2])).resolve()
        if not resolved.is_file():
            raise ValueError(f"Missing registered source: {resolved}")
        relative = Path(os.path.relpath(resolved, output)).as_posix()
        return match[1] + escape(relative, quote=True) + match[3]
    project = re.sub(r'(<File Path=")([^"]+)(")', absolute, project)
    extra = ""
    for order, name in enumerate(("sdram_bist.v", "top_sdram_diag.v"), 58):
        relative = Path(os.path.relpath(HERE/name, output)).as_posix()
        extra += f'''            <File Path="{relative}">
                <FileInfo>
                    <Attr Name="AutoExcluded" Val="false"/>
                    <Attr Name="UsedInSyn" Val="true"/>
                    <Attr Name="UsedInP&R" Val="true"/>
                    <Attr Name="BelongTo" Val="design_1"/>
                    <Attr Name="CompileOrder" Val="{order}"/>
                </FileInfo>
            </File>
'''
    project = project.replace("</Verilog>", extra + "</Verilog>", 1)
    project = project.replace("<Name>project</Name>", "<Name>sdram_diag</Name>")
    project = project.replace("<LABEL>top</LABEL>", "<LABEL>top_sdram_diag</LABEL>")
    project = project.replace("<MODULE>top</MODULE>", "<MODULE>top_sdram_diag</MODULE>")
    (output / "sdram_diag.al").write_text(project, encoding="utf-8", newline="\n")
    script = f'''cd {tcl_path(output)}
set out {tcl_path(output)}
if {{[catch {{
    import_device eagle_s20.db -package EG4S20BG256
    open_project {tcl_path(output/'sdram_diag.al')} -single_run
    load_run_param -run syn_1
    elaborate -top top_sdram_diag
    read_adc {tcl_path(PROJECT/'constraints/pin.adc')}
    read_sdc {tcl_path(PROJECT/'constraints/timing.sdc')}
    commit_param -step rtl
    optimize_rtl
    read_sdc {tcl_path(HERE/'diag.sdc')}
    set flags [get_regs {{*pass_meta *fail_meta}}]
    set dips [get_regs {{*dip_meta[*]}}]
    puts "DIAG_CDC flags=[llength $flags] dips=[llength $dips]"
    if {{[llength $flags] != 2 || [llength $dips] != 4}} {{
        error "Expected two terminal flags and four active switch first stages"
    }}
    report_area -file $out/rtl_area.rpt
    commit_param -step gate
    optimize_gate -packarea $out/gate.area
    legalize_phy_inst
'''
    if stage == "full":
        script += r'''    commit_param -step place
    place
    commit_param -step route
    route
    update_timing -mode final
    report_timing_status -file $out/timing_status.rpt
    report_timing_summary -file $out/timing_summary.rpt
    check_timing -verbose -file $out/timing_check.rpt
    foreach {clock period} {sd_card_clk 10 ext_mem_clk 25 ext_mem_clk_sft 25 video_clk 40 hdmi_5x_clk 8} {
        set actual [get_property -max PERIOD [get_clocks $clock]]
        if {abs($actual-$period)>0.001} { error "Unexpected period for $clock: $actual" }
    }
    set f [open $out/timing_status.rpt r]
    set timing [read $f]; close $f
    if {![regexp {SWNS:\s*([-+0-9.]+)ns,\s*STNS:\s*([-+0-9.]+)ns} $timing -> sw st] ||
        ![regexp {HWNS:\s*([-+0-9.]+)ns,\s*HTNS:\s*([-+0-9.]+)ns} $timing -> hw ht]} {
        error "Cannot parse timing report"
    }
    if {$sw<0 || $st<0 || $hw<0 || $ht<0} { error "Timing failed: setup=$sw hold=$hw" }
    commit_param -step bitgen
    bitgen -bit $out/top_sdram_diag.bit
    puts "DIAG_PHYSICAL_COMPLETE setup=$sw hold=$hw"
'''
    script += '''} message]} {
    puts stderr "DIAG_BUILD_FAIL: $message"
    exit 1
}
puts "DIAG_BUILD_COMPLETE"
exit
'''
    (output / "build.tcl").write_text(script, encoding="utf-8", newline="\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--td", type=Path, required=True)
    parser.add_argument("--stage", choices=("synth", "full"), default="synth")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--timeout", type=int, default=1800)
    args = parser.parse_args()
    tool = args.td.resolve()
    if not tool.is_file():
        parser.error("TD executable does not exist")
    # TD 6.2.168116 opens relative names before normalizing '..'. Keep its raw
    # Windows file names below MAX_PATH, including the long HDMI source name.
    output = (args.output or PROJECT / "build" / ("md_" +
        dt.datetime.now(dt.timezone.utc).strftime("%H%M%S%f"))).resolve()
    output.mkdir(parents=True, exist_ok=False)
    before = source_hashes()
    tool_hash = sha(tool)
    prepare(output, args.stage)
    record = {"stage": args.stage, "top": "top_sdram_diag", "device": "EG4S20BG256",
              "tool": str(tool), "tool_sha256": tool_hash, "sources": before,
              "programmed": False, "status": "failed"}
    start = time.monotonic()
    try:
        proc = subprocess.run([str(tool), (output / "build.tcl").as_posix()], cwd=PROJECT,
                              capture_output=True, timeout=args.timeout)
        raw = proc.stdout + proc.stderr
        record["returncode"] = proc.returncode
    except subprocess.TimeoutExpired as error:
        raw = (error.stdout or b"") + (error.stderr or b"") + b"\nDIAG_TIMEOUT\n"
        record["timed_out"] = True
    (output / "td.log").write_bytes(raw)
    log = raw.decode("utf-8", errors="replace")
    record["elapsed_seconds"] = round(time.monotonic()-start, 3)
    version = re.search(r"Tang Dynasty, V([^\s]+)", log)
    record["td_version"] = version[1] if version else None
    record["diagnostics"] = [s for s in log.splitlines() if
                             re.search(r"WARNING|ERROR|FATAL", s)]
    # Same precise intermediate SDRAM relocation notice reviewed in the main
    # build runner. It is acceptable only after completed route and bitgen.
    physical_complete = ("DIAG_PHYSICAL_COMPLETE" in log and
                         "End Stage 5 | Design Rule Check" in log)
    relocation = [s for s in record["diagnostics"] if re.search(
        r"PHY-7002 CRITICAL-WARNING: Instance U3/sdram location .*will be moved during placement", s)]
    record["reviewed_sdram_relocation_warnings"] = relocation
    record["errors_or_critical_warnings"] = [s for s in record["diagnostics"] if
        re.search(r"CRITICAL-WARNING|\bERROR\b|\bFATAL\b", s) and not
        (args.stage == "full" and physical_complete and s in relocation)]
    record["timing_checks"] = {}
    if args.stage == "full":
        report = output / "timing_check.rpt"
        check_text = report.read_text(encoding="utf-8", errors="replace") if report.is_file() else ""
        for check in ("no clock", "clock definition", "invalid constraint",
                      "pll/clock buffer clock constraints", "combinational loops",
                      "soft fifo timing exception constraints",
                      "no path constraints", "shadowed/ignored timing exception constraints"):
            match = re.search(r"checking " + re.escape(check) + r"\((\d+)\)", check_text)
            record["timing_checks"][check] = int(match[1]) if match else None
    record["sources_unchanged"] = source_hashes() == before
    record["tool_unchanged"] = sha(tool) == tool_hash
    record["build_complete"] = "DIAG_BUILD_COMPLETE" in log
    # A bitstream is an artifact, not proof of physical or board correctness.
    bit = output / "top_sdram_diag.bit"
    record["bitstream_sha256"] = sha(bit) if bit.is_file() else None
    if (record.get("returncode") == 0 and record["build_complete"] and
        record["sources_unchanged"] and record["tool_unchanged"] and
        not record["errors_or_critical_warnings"] and
        all(count == 0 for count in record["timing_checks"].values()) and
        (args.stage == "synth" or record["bitstream_sha256"])):
        record["status"] = "passed"
    (output / "results.json").write_text(json.dumps(record, indent=2), encoding="utf-8")
    print(record["status"], "evidence:", output)
    return 0 if record["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
