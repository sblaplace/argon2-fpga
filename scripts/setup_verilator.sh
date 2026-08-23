#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VENV_DIR_DEFAULT="$ROOT_DIR/.venv/verilator"
VENV_DIR="${VERILATOR_VENV:-$VENV_DIR_DEFAULT}"
VERILATOR_PYPI_VERSION="${VERILATOR_PYPI_VERSION:-5.48.0}"
MODE="help"
RUN_CMD=()

usage() {
    cat <<EOF
Setup helper for the PyPI Verilator wheel.

Usage:
  $(basename "$0") [--venv DIR] [--install]
  $(basename "$0") [--venv DIR] --print-env
  $(basename "$0") [--venv DIR] --run <command...>

Options:
  --venv DIR     Virtualenv path (default: $VENV_DIR_DEFAULT)
  --install      Create/update the venv and print a short summary
  --print-env    Print shell exports for VERILATOR / VERILATOR_ROOT
  --run CMD...   Run CMD with VERILATOR / VERILATOR_ROOT set
  -h, --help     Show this help

Environment overrides:
  VERILATOR_VENV          Virtualenv path
  VERILATOR_PYPI_VERSION  Wheel version to install (default: 5.48.0)

Examples:
  $(basename "$0") --install
  eval "$(./scripts/$(basename "$0") --print-env)"
  ./scripts/$(basename "$0") --run make -C sim SIM=verilator NP=8 fill
EOF
}

while (($#)); do
    case "$1" in
        --venv)
            shift
            [[ $# -gt 0 ]] || { echo "error: --venv requires a path" >&2; exit 2; }
            VENV_DIR="$1"
            ;;
        --install)
            MODE="install"
            ;;
        --print-env)
            MODE="print-env"
            ;;
        --run)
            MODE="run"
            shift
            [[ $# -gt 0 ]] || { echo "error: --run requires a command" >&2; exit 2; }
            RUN_CMD=("$@")
            break
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

ensure_verilator() {
    mkdir -p "$(dirname "$VENV_DIR")"
    if [[ ! -x "$VENV_DIR/bin/python" ]]; then
        python3 -m venv "$VENV_DIR"
    fi
    "$VENV_DIR/bin/python" -m pip install --upgrade pip >/dev/null
    "$VENV_DIR/bin/python" -m pip install "verilator==$VERILATOR_PYPI_VERSION" >/dev/null
}

verilator_root() {
    "$VENV_DIR/bin/python" - <<'PY'
import os
import verilator
print(os.path.dirname(verilator.__file__))
PY
}

ensure_verilator
VERILATOR_BIN="$VENV_DIR/bin/verilator-cli"
VERILATOR_ROOT_DIR="$(verilator_root)"

case "$MODE" in
    install)
        cat <<EOF
Installed PyPI Verilator ${VERILATOR_PYPI_VERSION}
  venv:           $VENV_DIR
  VERILATOR:      $VERILATOR_BIN
  VERILATOR_ROOT: $VERILATOR_ROOT_DIR

Use it with:
  eval "\$($(printf '%q' "$0") --venv $(printf '%q' "$VENV_DIR") --print-env)"

Or run a command directly:
  $(printf '%q' "$0") --venv $(printf '%q' "$VENV_DIR") --run make -C sim SIM=verilator NP=8 fill
EOF
        ;;
    print-env)
        printf 'export VERILATOR=%q\n' "$VERILATOR_BIN"
        printf 'export VERILATOR_ROOT=%q\n' "$VERILATOR_ROOT_DIR"
        ;;
    run)
        export VERILATOR="$VERILATOR_BIN"
        export VERILATOR_ROOT="$VERILATOR_ROOT_DIR"
        exec "${RUN_CMD[@]}"
        ;;
    help)
        usage
        ;;
    *)
        echo "error: unhandled mode: $MODE" >&2
        exit 2
        ;;
esac
