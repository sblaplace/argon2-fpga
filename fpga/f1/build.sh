#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build helper for the F1 CL (cl_argon2) — wraps the HDK flow and the
# standalone lint/sim checks from docs/F1_BRINGUP.md.
#
# Usage:
#   ./fpga/f1/build.sh lint [--np 8] [--top-module cl_argon2]
#   ./fpga/f1/build.sh sim  [--np 8]
#   ./fpga/f1/build.sh emit-top [--np 8] [--top-module cl_dram_dma] [--out /tmp/cl_dram_dma.sv]
#   ./fpga/f1/build.sh dcp  [--np 8] [--top-module cl_dram_dma]
#   ./fpga/f1/build.sh host
#
# The N_P preset defaults to A2_N_P (or 1 when unset). For the measured
# high-throughput point use --np 8.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
F1="$ROOT/fpga/f1"
HDK="${AWS_FPGA_REPO_DIR:-}"

usage() {
  cat <<EOF
Usage: $0 {lint|sim|emit-top|dcp|host|all} [options]

Options:
  --np N              Parallel P units to use (1,2,4,8). Default: \
                      A2_N_P env var, else 1.
  --top-module NAME   Top-module name for emit-top/dcp. Default: \
                      A2_HDK_TOP env var, else cl_dram_dma.
  --out PATH          Output path for emit-top. Default: \
                      /tmp/<top-module>_argon2_np<N>.sv
  -h, --help          Show this help.
EOF
}

find_verilator() {
  local vltor="${VERILATOR:-}"
  if [[ -z "$vltor" ]]; then
    if command -v verilator >/dev/null 2>&1; then
      vltor=verilator
    elif command -v verilator-cli >/dev/null 2>&1; then
      vltor=verilator-cli
    fi
  fi
  printf '%s' "$vltor"
}

validate_np() {
  case "$1" in
    1|2|4|8) ;;
    *) echo "invalid --np '$1' (expected 1, 2, 4, or 8)" >&2; exit 2 ;;
  esac
}

cmd="${1:-lint}"
if [[ $# -gt 0 ]]; then
  shift
fi
NP="${A2_N_P:-1}"
TOP_MODULE="${A2_HDK_TOP:-cl_dram_dma}"
OUT_PATH="${A2_TOP_OUT:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --np)
      [[ $# -ge 2 ]] || { echo "--np requires a value" >&2; exit 2; }
      NP="$2"
      shift 2
      ;;
    --top-module)
      [[ $# -ge 2 ]] || { echo "--top-module requires a value" >&2; exit 2; }
      TOP_MODULE="$2"
      shift 2
      ;;
    --out)
      [[ $# -ge 2 ]] || { echo "--out requires a value" >&2; exit 2; }
      OUT_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

validate_np "$NP"

emit_top() {
  local out="${OUT_PATH:-/tmp/${TOP_MODULE}_argon2_np${NP}.sv}"
  python3 "$F1/emit_hdk_top.py" --np "$NP" --module-name "$TOP_MODULE" --out "$out"
  echo "Generated top wrapper: $out"
  echo "  top module : $TOP_MODULE"
  echo "  default N_P: $NP"
}

lint() {
  local vltor
  vltor="$(find_verilator)"
  echo "== lint: iverilog (if available), N_P=$NP =="
  if command -v iverilog >/dev/null 2>&1; then
    iverilog -g2012 -Pcl_argon2.N_P="$NP" -I"$ROOT/rtl/include" -I"$F1/design" \
      -o /tmp/cl_argon2.lint.out "$F1/design/cl_argon2.sv" -f "$F1/filelist.f" \
      && echo "iverilog: OK"
  else
    echo "iverilog not on PATH — skipping (Python KAT still valid: make test)"
  fi
  echo "== lint: verilator (if available), N_P=$NP =="
  if [[ -n "$vltor" ]]; then
    "$vltor" --lint-only -GN_P="$NP" -I"$ROOT/rtl/include" -I"$F1/design" \
      -f "$F1/filelist.f" "$F1/design/cl_argon2.sv" && echo "verilator: OK ($vltor)"
  else
    echo "verilator not on PATH — skipping"
  fi
}

sim() {
  local vltor
  vltor="$(find_verilator)"
  echo "== vectors =="
  python3 -m tests.dump_vectors
  echo "== sim: make -C sim cl NP=$NP =="
  if command -v iverilog >/dev/null 2>&1; then
    make -C "$ROOT/sim" cl "NP=$NP"
  elif [[ -n "$vltor" ]]; then
    make -C "$ROOT/sim" SIM=verilator VERILATOR="$vltor" cl "NP=$NP"
  else
    echo "No simulator on PATH — install iverilog (yum/apt) or verilator"
    echo "Vectors are still dumped under sim/gen/ for host KAT."
    exit 0
  fi
}

dcp() {
  local example top_out backup
  if [[ -z "$HDK" ]]; then
    echo "Set AWS_FPGA_REPO_DIR to your aws-fpga checkout and source hdk_setup.sh" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$HDK/hdk_setup.sh"
  example="$HDK/hdk/cl/examples/cl_dram_dma"
  if [[ ! -d "$example" ]]; then
    echo "HDK example not found at $example" >&2
    exit 1
  fi

  top_out="$example/design/${TOP_MODULE}.sv"
  backup="$top_out.argon2.bak"
  if [[ -f "$top_out" && ! -f "$backup" ]]; then
    cp "$top_out" "$backup"
    echo "Backed up existing top to $backup"
  fi

  local prev_out="${OUT_PATH:-}"
  OUT_PATH="$top_out"
  emit_top
  OUT_PATH="$prev_out"
  echo "Building DCP from $example using top $TOP_MODULE (N_P=$NP)..."
  echo "  The generated wrapper includes sources from this checkout via relative paths."
  echo "  Keep $ROOT in place until the HDK compile finishes."
  echo ""
  echo "  Timing: source fpga/f1/build/synth_timing.tcl into the HDK synth tcl"
  echo "  (or set the RETIMING properties on synth_1) for the 250 MHz BlaMka"
  echo "  DSP-register packing. Core/OCL/DDR are all on clk_main_a0 — no CDC."
  echo "  See docs/TIMING_250MHZ.md for the measured 250 MHz projection."
  echo ""
  (cd "$example" && aws_build_dcp_from_cl -foreground)
}

host() {
  echo "== host: generate vectors =="
  (cd "$ROOT" && python3 -m tests.dump_vectors)

  echo "== host: SIM_HOST smoke tests (no SDK needed) =="
  gcc -DSIM_HOST -O2 -Wall -Wextra -Werror -std=c11 "$F1/host/argon2_cl.c" -o /tmp/argon2_cl_sim
  (cd "$ROOT" && /tmp/argon2_cl_sim --check-sim-vectors)
  (cd "$ROOT" && /tmp/argon2_cl_sim --type i --passes 2 --lane-len 8 \
    --mem-blocks 8 --init sim/gen/fill_i_init.hex >/dev/null)
  if /tmp/argon2_cl_sim --lane-len 8 --mem-blocks 32 >/dev/null 2>&1; then
    echo "argon2_cl accepted an inconsistent p=1 memory geometry" >&2
    exit 1
  fi
  if /tmp/argon2_cl_sim --p4 --lane-len 8 --mem-blocks 32 >/dev/null 2>&1; then
    echo "argon2_cl accepted p=4 without a cross-channel read router" >&2
    exit 1
  fi
  gcc -DSIM_HOST -O2 -Wall -Wextra -Werror -std=c11 "$F1/host/bw_test.c" -o /tmp/bw_test_sim
  /tmp/bw_test_sim --all --bytes $((32 * 1024)) --iters 1
  echo "host SIM_HOST: OK"

  if [[ -n "$HDK" && -d "$HDK/sdk/userspace/include" ]]; then
    # shellcheck source=/dev/null
    source "$HDK/sdk_setup.sh" 2>/dev/null || true
    echo "== host: real SDK build =="
    gcc -O2 -Wall -Wextra -Werror -std=c11 \
      -I"$HDK/sdk/userspace/include" \
      "$F1/host/argon2_cl.c" \
      -L"$HDK/sdk/userspace/lib" -lfpga_mgmt -lfpga_pci -o /tmp/argon2_cl && echo "argon2_cl: OK"
    gcc -O2 -Wall -Wextra -Werror -std=c11 \
      -I"$HDK/sdk/userspace/include" \
      "$F1/host/bw_test.c" \
      -L"$HDK/sdk/userspace/lib" -lfpga_mgmt -lfpga_pci -o /tmp/bw_test && echo "bw_test: OK"
  else
    echo "HDK/SDK not found — skipping real host build (SIM_HOST already built)"
  fi
}

case "$cmd" in
  lint) lint ;;
  sim) sim ;;
  emit-top) emit_top ;;
  dcp) dcp ;;
  host) host ;;
  all) lint; host ;;
  *) usage >&2; exit 2 ;;
esac
