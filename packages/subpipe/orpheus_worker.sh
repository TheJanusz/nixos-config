#!/usr/bin/env bash
# Launcher: prefer CUDA wheel venv, else Nix CPU worker.
set -euo pipefail

VENV="${SUBPIPE_ORPHEUS_VENV:-${XDG_DATA_HOME:-$HOME/.local/share}/subpipe/orpheus-venv}"
# Driver + any Nix libstdc++ path injected by makeWrapper via LD_LIBRARY_PATH.
export LD_LIBRARY_PATH="/run/opengl-driver/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
# Installed layout: $out/lib/subpipe/orpheus_worker.sh
WORKER="${SUBPIPE_ORPHEUS_WORKER_PY:-$ROOT/orpheus_worker.py}"
CPU_WORKER="${SUBPIPE_ORPHEUS_WORKER_CPU:-$(cd "$ROOT/../../bin" 2>/dev/null && pwd)/subpipe-orpheus-worker-cpu}"

if [[ -x "$VENV/bin/python" ]]; then
  export PYTHONNOUSERSITE=1
  exec "$VENV/bin/python" "$WORKER" "$@"
fi

exec "$CPU_WORKER" "$@"
