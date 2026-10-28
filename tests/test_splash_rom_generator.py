"""Check generated synchronous ROM values, latency, padding and address aliasing."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "splash_generator", REPO / "project/tools/gen_splash_rom.py")
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class SplashRomTests(unittest.TestCase):
    def test_clocked_reads_across_banks_and_padding(self):
        portable = REPO.parent / "iverilog-portable/ucrt64"
        compiler = shutil.which("iverilog") or str(portable / "bin/iverilog.exe")
        runtime = shutil.which("vvp") or str(portable / "bin/vvp.exe")
        if not Path(compiler).is_file() or not Path(runtime).is_file():
            self.skipTest("Icarus Verilog is required for generated-ROM simulation")
        env = dict(os.environ)
        env["PATH"] = str(Path(compiler).parent) + os.pathsep + env["PATH"]
        backend = Path(compiler).resolve().parent.parent / "lib/ivl"
        compile_args = [compiler] + (["-B", str(backend)] if backend.is_dir() else [])
        run_args = [runtime] + (["-M", str(backend)] if backend.is_dir() else [])
        sizes = (1, 1024, 1025, 4464, 5236, 8192)
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            sources, instances, checks = [], [], []
            for n, size in enumerate(sizes):
                words = [((i * 73) ^ (i >> 2) ^ ((i >> 10) * 91) ^ 0x5a) & 255
                         for i in range(size)]
                source = folder / f"rom{n}.v"
                generator.emit_rom(source, f"rom{n}", words, "independent test pattern")
                sources.append(source)
                padded = ((size + 1023) // 1024) * 1024
                mask = (1 << (padded - 1).bit_length()) - 1
                instances.append(f"wire[8:0] q{n}; rom{n} r{n}(clk,addr,q{n});")
                checks.append(f"""
                    a = address & {mask};
                    if(a >= {padded}) expected = 9'bxxxxxxxxx;
                    else if(a >= {size}) expected = 0;
                    else expected = ((a*73) ^ (a>>2) ^ ((a>>10)*91) ^ 90) & 255;
                    if(q{n} !== expected) $fatal(1,
                        "ROM{n} address=%h got=%h expected=%h",address,q{n},expected);
                """)
            outputs = ",".join(f"q{n}" for n in range(len(sizes)))
            bench = folder / "tb.v"
            bench.write_text("""`timescale 1ns/1ps
module tb;
reg clk=0; always #5 clk=~clk;
reg[12:0] addr=0;
""" + "\n".join(instances) + f"""
integer i,a; reg[8:0] expected; reg[{len(sizes)*9-1}:0] held;
task read_word; input[12:0] address; begin
  @(negedge clk);addr=address;@(posedge clk);#1;
  {''.join(checks)}
  held={{{outputs}}};addr=~address;#2;
  if({{{outputs}}} !== held) $fatal(1,"output changed without a clock edge");
end endtask
initial begin
  for(i=0;i<8192;i=i+1)read_word(i);
  for(i=8191;i>=0;i=i-1)read_word(i);
  for(i=0;i<2048;i=i+1)read_word((i*317+1021)&8191);
  $display("PASS generated ROM: values, latency, padding and aliases");$finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
""", encoding="utf-8")
            compile_result = subprocess.run(
                compile_args + ["-g2012", "-s", "tb", "-o", str(folder / "tb.vvp")]
                + list(map(str, sources)) + [str(bench)],
                capture_output=True, env=env, timeout=60)
            self.assertEqual(compile_result.returncode, 0,
                             compile_result.stderr.decode(errors="replace"))
            result = subprocess.run(run_args + [str(folder / "tb.vvp")], cwd=folder,
                                    capture_output=True, env=env, timeout=60)
            output = (result.stdout + result.stderr).decode(errors="replace")
            self.assertEqual(result.returncode, 0, output)
            self.assertIn("PASS generated ROM", output)


if __name__ == "__main__":
    unittest.main()
