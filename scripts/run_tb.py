#!/usr/bin/env python3
"""
run_tb.py — self-checking testbench runner.

Discovers every hdl/**/tb_*.v, compiles it with Icarus Verilog, executes the
simulation, and requires BOTH:
  1. iverilog/vvp exit code 0 (no compile/runtime errors), AND
  2. the literal marker "PASS" in the simulation output.

The PASS-marker requirement is the forcing function: a testbench that
finishes without asserting all its vectors (e.g. a silent early $finish, or a
testbench that never checks anything) still fails CI. This keeps the pipeline
green only when the RTL is genuinely verified, never vacuously.

Usage: python3 scripts/run_tb.py [optional path to iverilog bin dir]
Exit: 0 if all testbenches pass, 1 otherwise.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HDL_DIR = os.path.join(ROOT, "hdl")
PASS_MARKER = "PASS"


def find_testbenches(hdl_dir):
    tbs = []
    for dirpath, _dirs, files in os.walk(hdl_dir):
        for f in sorted(files):
            # match both tb_foo.v and foo_tb.v conventions; keep it simple:
            if re.match(r"^(tb_.*|.*_tb)\.v$", f):
                tbs.append(os.path.join(dirpath, f))
    return sorted(tbs)


def run_one(tb_path, iverilog, vvp):
    """Returns (ok: bool, log: str)."""
    workdir = tempfile.mkdtemp(prefix="rtl_smoke_")
    binary = os.path.join(workdir, "sim")
    vlog = os.path.join(workdir, "compile.log")
    simlog = os.path.join(workdir, "sim.log")

    # iverilog needs the DUT on a module-library path. We compile from the
    # hdl/ root and use -y rtl so a module named `foo` is resolved from
    # hdl/rtl/foo.v (the standard Verilog source-library convention).
    rtl_lib = os.path.join(HDL_DIR, "rtl")
    cmd = [iverilog, "-g2005-sv", "-y", rtl_lib, "-o", binary, tb_path]
    try:
        cp = subprocess.run(
            cmd, cwd=HDL_DIR, capture_output=True, text=True,
            timeout=120,
        )
        with open(vlog, "w") as fh:
            fh.write(cp.stdout + cp.stderr)
    except subprocess.TimeoutExpired:
        return False, "iverilog timeout\n"

    if cp.returncode != 0:
        return False, open(vlog).read()

    try:
        sp = subprocess.run(
            [vvp, binary], cwd=HDL_DIR, capture_output=True, text=True, timeout=120)
        with open(simlog, "w") as fh:
            fh.write(sp.stdout + sp.stderr)
    except subprocess.TimeoutExpired:
        return False, "vvp timeout\n"

    if sp.returncode != 0:
        return False, open(simlog).read()

    out = open(simlog).read()
    if PASS_MARKER not in out:
        return False, (
            f"simulation did not print '{PASS_MARKER}' (silent/incomplete pass)\n"
            + out
        )
    return True, out


def main():
    iverilog = shutil.which("iverilog")
    vvp = shutil.which("vvp")
    if not iverilog or not vvp:
        print("ERROR: iverilog/vvp not on PATH")
        return 1

    tbs = find_testbenches(HDL_DIR)
    if not tbs:
        print("ERROR: no tb_*.v / *_tb.v testbenches found under hdl/")
        return 1

    failures = 0
    for tb in tbs:
        rel = os.path.relpath(tb, ROOT)
        print(f"[run] {rel}")
        ok, log = run_one(tb, iverilog, vvp)
        print(log.rstrip())
        if not ok:
            failures += 1
            print(f"[FAIL] {rel}\n")
        else:
            print(f"[OK]   {rel}\n")

    if failures:
        print(f"{failures} testbench(s) FAILED")
        return 1
    print("ALL TESTBENCHES PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
