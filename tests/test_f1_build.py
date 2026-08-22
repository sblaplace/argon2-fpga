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
            self.assertIn('`include "', text)
            self.assertIn("cl_argon2.sv", text)
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


if __name__ == "__main__":
    unittest.main()
