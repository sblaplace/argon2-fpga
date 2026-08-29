import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EMIT = ROOT / "fpga" / "f1" / "emit_hdk_top.py"


class TestF1BuildHelpers(unittest.TestCase):
    def test_emit_hdk_top_np8(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            out = Path(tmpdir) / "cl_dram_dma.sv"
            subprocess.run(
                [
                    sys.executable,
                    str(EMIT),
                    "--np",
                    "8",
                    "--ctxs-per-ch",
                    "3",
                    "--module-name",
                    "cl_dram_dma",
                    "--out",
                    str(out),
                ],
                check=True,
                cwd=ROOT,
            )
            text = out.read_text()
            self.assertIn("`define A2_CL_TOP cl_dram_dma", text)
            self.assertIn("`define A2_DEFAULT_N_P 8", text)
            self.assertIn("`define A2_DEFAULT_CTXS_PER_CH 3", text)
            self.assertIn('`include "', text)
            self.assertIn("cl_argon2.sv", text)
            self.assertIn("argon2_lane_conc.sv", text)
            self.assertIn("argon2_fill_axi.sv", text)

    def test_emit_hdk_top_rejects_bad_np(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            out = Path(tmpdir) / "cl_dram_dma.sv"
            cp = subprocess.run(
                [
                    sys.executable,
                    str(EMIT),
                    "--np",
                    "3",
                    "--out",
                    str(out),
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(cp.returncode, 0)
            self.assertIn("--np must be one of", cp.stderr + cp.stdout)

    def test_emit_hdk_top_rejects_bad_ctxs(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            out = Path(tmpdir) / "cl_dram_dma.sv"
            cp = subprocess.run(
                [
                    sys.executable,
                    str(EMIT),
                    "--ctxs-per-ch",
                    "5",
                    "--out",
                    str(out),
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(cp.returncode, 0)
            self.assertIn("--ctxs-per-ch must be between 1 and 4", cp.stderr + cp.stdout)

    def test_host_sim_build_and_run(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            bin_path = Path(tmpdir) / "argon2_cl_sim"
            subprocess.run(
                [
                    "gcc",
                    "-DSIM_HOST",
                    "-O2",
                    "-Wall",
                    "-Wextra",
                    str(ROOT / "fpga" / "f1" / "host" / "argon2_cl.c"),
                    "-o",
                    str(bin_path),
                ],
                check=True,
                cwd=ROOT,
            )
            init_hex = ROOT / "sim" / "gen" / "fill_i_init.hex"
            if not init_hex.exists():
                subprocess.run([sys.executable, "-m", "tests.dump_vectors"], check=True, cwd=ROOT)

            # Check built-in sim vectors
            cp = subprocess.run([str(bin_path), "--check-sim-vectors"], capture_output=True, text=True, cwd=ROOT)
            self.assertEqual(cp.returncode, 0, msg=f"{cp.stdout}\n{cp.stderr}")
            self.assertIn("SIM_HOST PASS", cp.stdout)

            # Check multi-context 12-lane run (ctxs-per-ch = 3)
            cp2 = subprocess.run(
                [
                    str(bin_path),
                    "--type", "i",
                    "--passes", "2",
                    "--lane-len", "8",
                    "--mem-blocks", "8",
                    "--ctxs-per-ch", "3",
                    "--init", str(init_hex),
                    "--expect", str(init_hex),
                ],
                capture_output=True,
                text=True,
                cwd=ROOT,
            )
            self.assertEqual(cp2.returncode, 0, msg=f"{cp2.stdout}\n{cp2.stderr}")
            self.assertIn("total_lanes=12", cp2.stdout)
            self.assertIn("lane 11:", cp2.stdout)
            self.assertIn("argon2_cl: done", cp2.stdout)


if __name__ == "__main__":
    unittest.main()
