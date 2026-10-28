"""Check the SDRAM clock wrapper against the installed Anlogic ODDR model."""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]


class SdramForwardClockTests(unittest.TestCase):
    def test_forwarded_polarity_and_reset_continuity(self):
        tool_root = Path(os.environ.get("ANLOGIC_TD_ROOT",
            "E:/BaiduNetdiskDownload/HX4S20_Contest_202606/anlu/td"))
        model = tool_root / "sim_release/eg4/eg_logic_io.v"
        portable = REPO.parent / "iverilog-portable/ucrt64"
        compiler = shutil.which("iverilog") or str(portable / "bin/iverilog.exe")
        runtime = shutil.which("vvp") or str(portable / "bin/vvp.exe")
        if not model.is_file() or not Path(compiler).is_file() or not Path(runtime).is_file():
            self.skipTest("Requires Icarus and Anlogic EG4 ODDR model; set ANLOGIC_TD_ROOT")
        env = dict(os.environ)
        env["PATH"] = str(Path(compiler).parent) + os.pathsep + env["PATH"]
        backend = Path(compiler).resolve().parent.parent / "lib/ivl"
        comp = [compiler] + (["-B", str(backend)] if backend.is_dir() else [])
        run = [runtime] + (["-M", str(backend)] if backend.is_dir() else [])
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            # The library also contains protected models Icarus cannot read.
            # Compile only the exact, unedited, plaintext ODDR module.
            original = model.read_text()
            match = re.search(r"(?ms)^module EG_LOGIC_ODDR\s.*?^endmodule", original)
            self.assertIsNotNone(match)
            oddr = folder / "vendor_oddr.v"
            oddr.write_text(original[:original.index("module ")] +
                            "\n`timescale 1ns/1ps\n" + match[0] + "\n", encoding="utf-8")
            tb = folder / "tb.v"
            instances = []
            for n in (0, 1):
                instances.append(f"""
sdram #(.FORWARD_CLOCK_ODDR({n})) d{n}(
 .Clk(clk),.Clk_sft(shifted),.Rst(rst),
 .App_wr_en(1'b0),.App_wr_addr(21'd0),.App_wr_dm(4'd0),.App_wr_din(32'd0),
 .App_rd_en(1'b0),.App_rd_addr(21'd0));
""")
            tb.write_text("""`timescale 1ns/1ps
// Explicit simulation environment for the vendor model's global reset.
module glbl; reg gsrn=0; initial #1 gsrn=1; endmodule
module tb;
reg clk=0,shifted=0,rst=1;
always #12.5 clk=~clk;
initial begin #9.375;forever begin shifted=1;#12.5;shifted=0;#12.5;end end
""" + "".join(instances) + """
integer i; realtime previous_edge;
initial begin
 repeat(3) @(negedge shifted);
 previous_edge=$realtime;
 for(i=0;i<200;i=i+1) begin
  @(shifted);#0.2;
  if(d0.SDRAM_CLK !== shifted || d1.SDRAM_CLK !== shifted)
   $fatal(1,"forwarded clock polarity/edge mismatch");
  if(d1.sdram.clk !== shifted) $fatal(1,"SDRAM pin is disconnected");
  if(i>0 && ($realtime-previous_edge<12.49 || $realtime-previous_edge>12.51))
   $fatal(1,"forwarded clock edge lost or duplicated");
  previous_edge=$realtime;
  if(i%20==3)rst=0;
  if(i%20==13)rst=1;
 end
 $display("PASS SDRAM forward clock: 200 edges, both modes, reset continuity");$finish;
end
initial begin #10000;$fatal(1,"clock test timeout");end
endmodule
""", encoding="utf-8")
            image = folder / "tb.vvp"
            # This vendor library uses Verilog identifiers reserved by SV.
            result = subprocess.run(comp + ["-g2005", "-s", "tb", "-s", "glbl",
                "-I", str(REPO / "project/vendor"), "-o", str(image),
                str(REPO / "project/vendor/sdram.v"),
                str(REPO / "tests/sim/stubs/sdr_as_ram_early_data_model.v"),
                str(oddr), str(tb)], capture_output=True, env=env, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
            result = subprocess.run(run + [str(image)], capture_output=True, env=env, timeout=30)
            output = (result.stdout + result.stderr).decode(errors="replace")
            self.assertEqual(result.returncode, 0, output)
            self.assertIn("PASS SDRAM forward clock", output)


if __name__ == "__main__":
    unittest.main()
