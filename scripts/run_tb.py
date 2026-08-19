#!/usr/bin/env python3
"""
run_tb.py — self-checking testbench runner.

Runs the real verification suites and requires BOTH:
  1. the build exit code 0 (no compile/runtime errors), AND
  2. the literal marker "PASS" in the simulation output.

The PASS-marker requirement is the forcing function: a testbench that
finishes without asserting all its vectors (e.g. a silent early $finish, or a
testbench that never checks anything) still fails CI.

Suites:
  * sim/  — `make -C sim` (Icarus) and `make -C sim cl`: the eight unit
    benches (blake2b G, BlaMka, index, compress, addr-gen, fill, RFC p=4
    fill, AXI-MM) plus the 4-channel F1 CL top bench tb_cl_argon2.
    This is the suite the CL bugs used to rot behind — run it.
  * hdl/ — any legacy tb_*.v / *_tb.v benches found there (kept for
    backwards compatibility).

Usage: python3 scripts/run_tb.py
Exit: 0 if all testbenches pass, 1 otherwise.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HDL_DIR = os.path.join(ROOT, "hdl")
SIM_DIR = os.path.join(ROOT, "sim")
PASS_MARKER = "PASS"


def find_testbenches(hdl_dir):
    tbs = []
    for dirpath, _dirs, files in os.walk(hdl_dir):
        for f in sorted(files):
            if re.match(r"^(tb_.*|.*_tb)\.v$", f):
                tbs.append(os.path.join(dirpath, f))
    return sorted(tbs)


def check_output(label, cp, require_pass):
    """Print a subprocess result and return ok."""
    out = (cp.stdout or "") + (cp.stderr or "")
    print(out.rstrip())
    if cp.returncode != 0:
        print(f"[FAIL] {label}: exit code {cp.returncode}\n")
        return False
    if require_pass and PASS_MARKER not in out:
        print(f"[FAIL] {label}: output did not contain '{PASS_MARKER}'\n")
        return False
    print(f"[OK]   {label}\n")
    return True


def run_streaming(cmd, cwd, timeout, label, require_pass):
    """Run a command, streaming its output live (so CI logs show exactly
    which bench stalls), and kill the whole process GROUP on timeout —
    a hung grandchild (vvp under make) would otherwise wedge the job."""
    import os
    import signal

    buf = []
    print(f"[run] {' '.join(cmd)}\n", flush=True)
    with subprocess.Popen(
        cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, start_new_session=True,
    ) as proc:
        try:
            for line in proc.stdout:
                buf.append(line)
                print(line, end="", flush=True)
            rc = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            print(f"\n[FAIL] {label}: timed out after {timeout}s — killing "
                  f"process group", flush=True)
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except OSError:
                proc.kill()
            proc.wait()
            return False
    out = "".join(buf)
    if rc != 0:
        print(f"\n[FAIL] {label}: exit code {rc}\n")
        return False
    if require_pass and PASS_MARKER not in out:
        print(f"\n[FAIL] {label}: output did not contain '{PASS_MARKER}'\n")
        return False
    print(f"\n[OK]   {label}\n")
    return True


def run_sim_suite():
    ok = True
    if not os.path.isdir(SIM_DIR):
        return ok
    # Unit benches + RFC p=4 + AXI (Icarus). Explicit `all`: the Makefile's
    # first rule is the perf bench, and a bare `make` used to pick that up.
    ok &= run_streaming(
        ["make", "-C", SIM_DIR, "all"], cwd=ROOT, timeout=1200,
        label="sim: make -C sim all (all benches)", require_pass=True,
    )
    # 4-channel F1 CL top bench.
    ok &= run_streaming(
        ["make", "-C", SIM_DIR, "cl"], cwd=ROOT, timeout=1200,
        label="sim: make -C sim cl (tb_cl_argon2)", require_pass=True,
    )
    return ok


def run_legacy_hdl():
    import shutil
    import tempfile

    iverilog = shutil.which("iverilog")
    vvp = shutil.which("vvp")
    if not iverilog or not vvp:
        print("WARNING: iverilog/vvp not on PATH — skipping legacy hdl/ benches")
        return True

    ok = True
    for tb in find_testbenches(HDL_DIR):
        rel = os.path.relpath(tb, ROOT)
        workdir = tempfile.mkdtemp(prefix="rtl_smoke_")
        binary = os.path.join(workdir, "sim")
        print(f"[run] {rel}")
        cp = subprocess.run(
            [iverilog, "-g2005-sv", "-y", os.path.join(HDL_DIR, "rtl"),
             "-o", binary, tb],
            cwd=HDL_DIR, capture_output=True, text=True, timeout=120,
        )
        if not check_output(f"{rel} (compile)", cp, require_pass=False):
            ok = False
            continue
        cp = subprocess.run(
            [vvp, binary], cwd=HDL_DIR, capture_output=True, text=True,
            timeout=120,
        )
        ok &= check_output(f"{rel} (run)", cp, require_pass=True)
    return ok


def main():
    if not os.path.isdir(SIM_DIR):
        print("ERROR: no sim/ directory")
        return 1
    ok = run_sim_suite()
    ok &= run_legacy_hdl()
    if not ok:
        print("TESTBENCH FAILURES")
        return 1
    print("ALL TESTBENCHES PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
