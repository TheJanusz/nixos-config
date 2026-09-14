#!/usr/bin/env bash
# Bootstrap a user venv with official PyTorch CUDA wheels for Orpheus.
# Nix torch-with-CUDA rebuilds Magma/bindings; wheels ship CUDA and are much faster.
set -euo pipefail

VENV="${SUBPIPE_ORPHEUS_VENV:-${XDG_DATA_HOME:-$HOME/.local/share}/subpipe/orpheus-venv}"
PY="${SUBPIPE_ORPHEUS_BOOTSTRAP_PYTHON:-}"
TORCH_INDEX="${SUBPIPE_ORPHEUS_TORCH_INDEX:-https://download.pytorch.org/whl/cu128}"

if [[ -z "$PY" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    PY=$(command -v python3)
  else
    echo "error: set SUBPIPE_ORPHEUS_BOOTSTRAP_PYTHON to a Python 3.11–3.13 interpreter" >&2
    exit 1
  fi
fi

echo "orpheus-cuda: bootstrap python=$PY"
echo "orpheus-cuda: venv=$VENV"
echo "orpheus-cuda: torch index=$TORCH_INDEX"

mkdir -p "$(dirname "$VENV")"
"$PY" -m venv "$VENV"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install -U pip wheel
python -m pip install torch --index-url "$TORCH_INDEX"
python -m pip install \
  "transformers>=4.45" \
  accelerate \
  snac \
  einops \
  soundfile \
  huggingface-hub \
  numpy

export LD_LIBRARY_PATH="/run/opengl-driver/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
python - <<'PY'
import torch
print("torch", torch.__version__)
print("cuda_available", torch.cuda.is_available())
print("device", torch.cuda.get_device_name(0) if torch.cuda.is_available() else None)
if not torch.cuda.is_available():
    raise SystemExit("CUDA not available in this venv — check NVIDIA driver / LD_LIBRARY_PATH")
PY

echo "orpheus-cuda: ready. Restart subpipe lektor to use: $VENV"
