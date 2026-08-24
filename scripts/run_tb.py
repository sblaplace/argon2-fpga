#!/usr/bin/env python3
"""
run_tb.py — self-checking testbench runner.

Runs the real verification suites and requires BOTH:
  1. the build exit code 0 (no compile/runtime errors), AND
  2. the literal marker "PASS" in the simulation output.

The PASS-marker requirement is the forcing function: a testbench that
finishes without asserting all its vectors (e.g. a silent early $finish, or
a testbench that never checks anything) still fails CI.

Suites:
  * sim/  — the Icarus targets, one make invocation PER BENCH with its own
    timeout and process-group kill, so a stall is named by the last target
    started instead of wedging the whole job: blake2b, blamka, index,
    compress, addr, fill, rfc, axi, cl (the 4-channel F1 CL top bench).
  * hdl/ — any legacy tb_*.v / *_tb.v benches found there (kept for
    backwards compatibility).

Usage: python3 scripts/run_tb.py
Exit: 0 if all testbenches pass, 1 otherwise.
"""
import os
import re
import signal
import subprocess
import sys
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HDL_DIR = os.path.join(ROOT, "hdl")
SIM_DIR = os.path.join(ROOT, "sim")
PASS_MARKER = "PASS"

SIM_TARGETS = ["blake2b", "blamka", "index", "compress", "addr",
               "fill", "discipline", "rfc", "p4", "axi", "axibig", "sweep", "cl"]
PER_TARGET_TIMEOUT = 300  # seconds; the geometry sweep is the long pole
# (~30 s on Verilator NP=1; Icarus/vvp is several times slower)
# N_P matrix: run the whole suite at every value in N_P_MATRIX (the Makefile
# passes NP through to each bench via -PN_P). The KAT vectors are N_P-
# independent, but the parallel-G path (N_P>1) is a distinct RTL topology that
# a single-N_P run would never exercise. Default = [1]; override via
# RUN_TB_NP (space/comma separated) env var, e.g. "1 8".
N_P_MATRIX = [int(x) for x in
              os.environ.get("RUN_TB_NP", "1").replace(",", " ").split()
              if x.strip()] or [1]


def gh_annotation(level, title, message):
    """Emit a workflow command annotation. Annotations are retrievable
    through the API even when the raw log download is not."""
    safe_t = title.replace(",", "%2C")
    safe_m = message.replace("\r", "").replace("\n", "%0A").replace(",", "%2C")
    print(f"::{level} title={safe_t}::{safe_m}", flush=True)


def find_testbenches(hdl_dir):
    tbs = []
    for dirpath, _dirs, files in os.walk(hdl_dir):
        for f in sorted(files):
            if re.match(r"^(tb_.*|.*_tb)\.v$", f):
                tbs.append(os.path.join(dirpath, f))
    return sorted(tbs)


def run_streaming(cmd, cwd, timeout, label, require_pass):
    """Run a command, streaming its output live, and kill the whole
    process GROUP on timeout (a hung grandchild under make — e.g. vvp —
    would otherwise outlive make and wedge the job)."""
    buf = []

    def reader(stream):
        for line in stream:
            buf.append(line)
            print(line, end="", flush=True)

    print(f"[run] {' '.join(cmd)}\n", flush=True)
    with subprocess.Popen(
        cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, start_new_session=True,
    ) as proc:
        t = threading.Thread(target=reader, args=(proc.stdout,), daemon=True)
        t.start()
        try:
            rc = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            print(f"\n[FAIL] {label}: timed out after {timeout}s — killing "
                  f"process group", flush=True)
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except OSError:
                proc.kill()
            proc.wait()
            t.join(timeout=5)
            gh_annotation("error", f"STALL: {label}",
                          "timed out after %ds; output tail:\n%s"
                          % (timeout, "".join(buf[-20:])[-800:]))
            return False
        t.join(timeout=5)
    out = "".join(buf)
    if rc != 0:
        print(f"\n[FAIL] {label}: exit code {rc}\n")
        gh_annotation("error", f"EXIT {rc}: {label}",
                      out[-800:])
        return False
    if require_pass and PASS_MARKER not in out:
        print(f"\n[FAIL] {label}: output did not contain '{PASS_MARKER}'\n")
        gh_annotation("error", f"NO-PASS: {label}",
                      out[-800:])
        return False
    print(f"\n[OK]   {label}\n")
    return True


def run_sim_suite():
    ok = True
    if not os.path.isdir(SIM_DIR):
        return ok
    sim_env = os.environ.get("SIM")
    # One make per (bench, N_P): a compile error, missing-PASS, or stall is
    # attributed to the exact (bench, N_P), and a stall can't block the rest
    # of the job for more than the per-target timeout. (A bare `make -C sim`
    # would also pick the Makefile's first rule — the perf bench — as the
    # default goal.) N_P comes via the Makefile `NP` var (-> -PN_P).
    for np in N_P_MATRIX:
        for tgt in SIM_TARGETS:
            cmd = ["make", "-C", SIM_DIR, tgt, f"NP={np}"]
            if sim_env:
                cmd.append(f"SIM={sim_env}")
            ok &= run_streaming(
                cmd, cwd=ROOT,
                timeout=PER_TARGET_TIMEOUT,
                label=f"sim: make -C sim {tgt} (N_P={np})", require_pass=True,
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
        if cp.returncode != 0:
            print((cp.stdout or "") + (cp.stderr or ""))
            print(f"[FAIL] {rel} (compile): exit code {cp.returncode}\n")
            ok = False
            continue
        cp = subprocess.run([vvp, binary], cwd=HDL_DIR,
                            capture_output=True, text=True, timeout=120)
        out = (cp.stdout or "") + (cp.stderr or "")
        print(out.rstrip())
        if cp.returncode != 0 or PASS_MARKER not in out:
            print(f"[FAIL] {rel} (run)\n")
            ok = False
        else:
            print(f"[OK]   {rel} (run)\n")
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
