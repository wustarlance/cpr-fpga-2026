"""Negative controls for TD acceptance: positive slack must not hide missing analysis."""
import sys
import subprocess
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "project"))
from td_report_checks import review_timing_check
from verify_td import summarize
import verify_td


def complete_report():
    names = ["no clock", "clock definition", "dummy node", "invalid constraint",
             "pll/clock buffer clock constraints", "combinational loops",
             "soft fifo timing exception constraints", "no path constraints",
             "shadowed/ignored timing exception constraints", "no input delay",
             "no output delay", "partial input delay", "partial output delay",
             "abnormal input delay"]
    summary = "\n".join(f"{i}. checking {name}({3 if i == 5 else 0}) (HIGH)"
                        for i, name in enumerate(names, 1))
    return summary + "\n" + "\n".join([
        "24 24 0 0 set_max_delay -from [get_regs {*u_page_status/u_transfer/src_hold[*]}] -to [get_regs {*u_page_status/u_transfer/dst_data[*]}] 40 -datapath_only",
        "36 36 0 0 set_max_delay -from [get_regs {*/primary_addr_gray_reg[*]}] -to [get_regs {*/sync_r1[*]}] -datapath_only 24.700",
        "36 36 0 0 set_max_delay -from [get_regs {*/primary_addr_gray_reg[*]}] -to [get_regs {*/sync_r1[*]}] -datapath_only 9.700",
    ])


class ReportChecks(unittest.TestCase):
    def test_three_plls_are_not_three_failures(self):
        self.assertEqual(review_timing_check(complete_report(), "top")["status"], "passed")

    def test_missing_clock_is_rejected(self):
        report = complete_report().replace("no clock(0)", "no clock(1)")
        self.assertEqual(review_timing_check(report, "top")["status"], "failed")

    def test_incomplete_report_is_rejected(self):
        self.assertEqual(review_timing_check("SWNS: 20.221ns", "top")["status"], "failed")

    def test_empty_mailbox_binding_is_rejected(self):
        report = complete_report().replace("24 24 0 0", "0 0 0 0")
        self.assertEqual(review_timing_check(report, "top")["status"], "failed")

    def test_overridden_fifo_bound_is_rejected(self):
        report = complete_report().replace("36 36 0 0", "36 18 0 18")
        self.assertEqual(review_timing_check(report, "top")["status"], "failed")

    def test_interface_review_cannot_pass_automatically(self):
        report = complete_report().replace("no input delay(0)", "no input delay(19)")
        self.assertEqual(review_timing_check(report, "top")["status"], "needs_review")

    def test_adc_requires_its_mailbox_too(self):
        self.assertEqual(review_timing_check(complete_report(), "top_adc")["status"], "failed")

    def test_bitgen_does_not_waive_sdram_relocation(self):
        warning = "PHY-7002 CRITICAL-WARNING: Instance U3/sdram location (12, 12) is not honored. Cell will be moved during placement."
        log = warning + "\nEnd Stage 5 | Design Rule Check\nCPR_BUILD_PASS top\n"
        self.assertEqual(summarize(log, "top", "full")["errors_or_critical_warnings"], [warning])

    def run_fixture(self, completion_marker):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory) / "project"
            physical = project / "build/top"
            physical.mkdir(parents=True)
            (project / "td_report_checks.py").write_text("# test fixture checker\n")
            (physical / "rtl_area.rpt").write_text("unit test fixture\n")
            (physical / "gate_area.rpt").write_text(
                "#lut 100 out of 19600 0.51%\n#reg 100 out of 19600 0.51%\n"
                "#bram 1 out of 64 1.56%\n#pll 3 out of 4 75.00%\n")
            (physical / "timing_status.rpt").write_text(
                "SWNS: 0.1ns, STNS: 0.0ns.\nHWNS: 0.01ns, HTNS: 0.0ns.\n")
            (physical / "timing_summary.rpt").write_text("unit test fixture\n")
            (physical / "timing_check.rpt").write_text(complete_report())
            for name in ("clock_summary.rpt", "clock_intersection.rpt", "timing_exception.rpt"):
                (physical / name).write_text("supplemental test fixture\n")
            (physical / "top.bit").write_bytes(b"unit test fixture, not a bitstream")
            destination = Path(directory) / "evidence"
            destination.mkdir()
            names = " ".join("{" + str(i) + "}" for i in range(12))
            log = ("Tang Dynasty, V6.2.168116\n"
                   f"CPR_PAGE_REGS hold={names} capture={names}\n" + completion_marker)
            process = subprocess.CompletedProcess([], 0, stdout=log.encode(), stderr=b"")
            with patch.object(verify_td, "PROJECT", project), patch.object(
                    verify_td.subprocess, "run", return_value=process):
                record = verify_td.run_top(Path("unit-test-td.exe"), "top", destination, 1, "full")
            copied_bit = (destination / "top/top.bit").is_file()
            return record, copied_bit

    def test_supplemental_reports_do_not_break_required_report_gate(self):
        record, copied_bit = self.run_fixture("CPR_BUILD_PASS top\n")
        self.assertEqual(record["status"], "passed")
        self.assertEqual(len(record["reports"]), 8)
        self.assertTrue(copied_bit)

    def test_stale_bit_is_rejected_without_fresh_build_marker(self):
        record, copied_bit = self.run_fixture("CPR_SYNTHESIS_PASS top\n")
        self.assertEqual(record["status"], "failed")
        self.assertNotIn("bitstream_sha256", record)
        self.assertFalse(copied_bit)


if __name__ == "__main__":
    unittest.main()
