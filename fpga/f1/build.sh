#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build helper for the F1 CL (cl_argon2) — wraps the HDK flow and the
# standalone lint/sim checks from docs/F1_BRINGUP.md.
#
# Usage:
#   ./fpga/f1/build.sh lint          # iverilog + verilator lint, no HDK
#   ./fpga/f1/build.sh sim           # sim/tb_cl_argon2 with iverilog or verilator
#   ./fpga/f1/build.sh dcp           # aws_build_dcp_from_cl (needs HDK)
#   ./fpga/f1/build.sh host          # build host binaries (needs SDK) + SIM_HOST fallback
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
F1="$ROOT/fpga/f1"
HDK="${AWS_FPGA_REPO_DIR:-}"

cmd="${1:-lint}"

lint() {
  echo "== lint: iverilog (if available) =="
  if command -v iverilog >/dev/null 2>&1; then
    iverilog -g2012 -I"$ROOT/rtl/include" -I"$F1/design" -o /tmp/cl_argon2.lint.out \
      "$F1/design/cl_argon2.sv" -f "$F1/filelist.f" && echo "iverilog: OK"
  else
    echo "iverilog not on PATH — skipping (Python KAT still valid: make test)"
  fi
  echo "== lint: verilator (if available) =="
  VLTOR="${VERILATOR:-}"
  if [[ -z "$VLTOR" ]]; then
    if command -v verilator >/dev/null 2>&1; then VLTOR=verilator
    elif command -v verilator-cli >/dev/null 2>&1; then VLTOR=verilator-cli
    fi
  fi
  if [[ -n "$VLTOR" ]]; then
    $VLTOR --lint-only -I"$ROOT/rtl/include" -I"$F1/design" -f "$F1/filelist.f" "$F1/design/cl_argon2.sv" && echo "verilator: OK ($VLTOR)"
  else
    echo "verilator not on PATH — skipping"
  fi
}

sim() {
  echo "== vectors =="
  python3 -m tests.dump_vectors
  echo "== sim: make -C sim cl =="
  VLTOR="${VERILATOR:-}"
  if [[ -z "$VLTOR" ]]; then
    if command -v verilator >/dev/null 2>&1; then VLTOR=verilator
    elif command -v verilator-cli >/dev/null 2>&1; then VLTOR=verilator-cli
    fi
  fi
  if command -v iverilog >/dev/null 2>&1; then
    make -C "$ROOT/sim" cl
  elif [[ -n "$VLTOR" ]]; then
    make -C "$ROOT/sim" SIM=verilator VERILATOR="$VLTOR" cl
  else
    echo "No simulator on PATH — install iverilog (yum/apt) or verilator"
    echo "Vectors are still dumped under sim/gen/ for host KAT."
    exit 0
  fi
}

dcp() {
  if [[ -z "$HDK" ]]; then
    echo "Set AWS_FPGA_REPO_DIR to your aws-fpga checkout and source hdk_setup.sh" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$HDK/hdk_setup.sh"
  # Copy CL into the example (non-destructive: use a staging copy)
  EXAMPLE="$HDK/hdk/cl/examples/cl_dram_dma"
  if [[ ! -d "$EXAMPLE" ]]; then
    echo "HDK example not found at $EXAMPLE" >&2; exit 1
  fi
  echo "Building DCP from $EXAMPLE with cl_argon2 as top..."
  echo "  (edit $EXAMPLE/design/cl_dram_dma.sv or set top to cl_argon2 per fpga/f1/README.md)"
  (cd "$EXAMPLE" && aws_build_dcp_from_cl -foreground)
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
  sim)  sim ;;
  dcp)  dcp ;;
  host) host ;;
  all)  lint; host ;;
  *) echo "Usage: $0 {lint|sim|dcp|host|all}" >&2; exit 2 ;;
esac
