"""Protect output rates and relative phases when selecting internal PLL feedback."""
from fractions import Fraction
from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET


REPO = Path(__file__).resolve().parents[1]


class PllClockContract(unittest.TestCase):
    def test_clock_rates_phases_and_generator_metadata(self):
        cases = {
            "sys_pll": (1000, 20, [(100, 0), (40, 0), (40, 180)]),
            "video_pll": (1000, 40, [(25, 0), (125, 0)]),
            "PLL_HDMI_AUDIO": (750, 30, [(75, 0), (375, 90), (Fraction(750, 61), 0)]),
        }
        for name, (vco_expected, factor, outputs) in cases.items():
            with self.subTest(pll=name):
                folder = REPO / "project/ip"
                source = (folder / f"{name}.v").read_text()
                params = dict(re.findall(r'\.(\w+)\(("[^"]+"|\d+)\)', source))
                self.assertEqual(params["FEEDBK_MODE"], '"NOCOMP"')
                self.assertEqual(params["FEEDBK_PATH"], '"VCO_PHASE_0"')
                self.assertIn(".fbclk(1'b0)", source)
                vco = Fraction(params["FIN"].strip('"')) * int(params["FBCLK_DIV"]) / int(params["REFCLK_DIV"])
                self.assertEqual(vco, vco_expected)
                self.assertTrue(300 <= vco <= 1200)
                self.assertEqual(int(params["FBCLK_DIV"]), factor)
                metadata = ET.parse(folder / f"{name}.ipc").getroot()
                self.assertEqual(metadata.findtext("Page1/feedback_mode"), "No compensation")
                self.assertEqual(int(metadata.findtext("Page3/multiplication_factor")), factor)
                self.assertEqual(int(metadata.findtext("Page3/division_factor")), int(params["REFCLK_DIV"]))
                vhdl = (folder / f"{name}.vhd").read_text()
                for key, value in params.items():
                    if key.startswith(("CLKC", "REFCLK", "FBCLK", "FEEDBK")):
                        self.assertRegex(vhdl, rf"\b{key}\s*=>\s*{re.escape(value)}(?:\s|,)")
                for n, (rate, phase) in enumerate(outputs):
                    divider = int(params[f"CLKC{n}_DIV"])
                    self.assertEqual(vco / divider, rate)
                    actual_phase = (Fraction(int(params[f"CLKC{n}_CPHASE"]) + 1)
                                    + Fraction(int(params[f"CLKC{n}_FPHASE"]), 8)) * 360 / divider
                    self.assertEqual(actual_phase % 360, phase)
                    clock = metadata.find(f"Page3/clocks/clock[id='{n}']")
                    self.assertIsNotNone(clock)
                    self.assertEqual(int(clock.findtext("clock_division_factor")), divider)
                    self.assertEqual(Fraction(clock.findtext("phase_shift").removesuffix("deg")), phase)

    def test_active_project_uses_the_local_audio_pll(self):
        project = (REPO / "project/project.al").read_text()
        self.assertIn('Path="ip/PLL_HDMI_AUDIO.ipc"', project)
        self.assertNotIn('Path="../05_lab_ex/lab_ex5_i2s/src/td_project/al_ip/PLL_HDMI_AUDIO.ipc"', project)


if __name__ == "__main__":
    unittest.main()
