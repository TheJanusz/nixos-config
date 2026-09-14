#!/usr/bin/env python3
"""Speaker diarization → JSON segments for subpipe.

Requires: pip install pyannote.audio
          HF_TOKEN with access to pyannote/speaker-diarization-3.1

Usage: python3 diarize_worker.py /path/to/audio.wav
Stdout: {"segments":[{"start":0.0,"end":1.2,"speaker":"SPEAKER_00"},...]}
"""
from __future__ import annotations

import json
import os
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: diarize_worker.py AUDIO.wav", file=sys.stderr)
        return 2
    audio = sys.argv[1]
    token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGING_FACE_HUB_TOKEN") or ""
    try:
        from pyannote.audio import Pipeline
    except ImportError as e:
        print(f"pyannote.audio not installed: {e}", file=sys.stderr)
        return 1

    kwargs = {}
    if token:
        kwargs["use_auth_token"] = token
    try:
        pipeline = Pipeline.from_pretrained(
            "pyannote/speaker-diarization-3.1", **kwargs
        )
    except Exception as e:
        print(f"failed to load pyannote pipeline: {e}", file=sys.stderr)
        return 1

    try:
        import torch

        if torch.cuda.is_available():
            pipeline.to(torch.device("cuda"))
    except Exception:
        pass

    diarization = pipeline(audio)
    segments = []
    for turn, _, speaker in diarization.itertracks(yield_label=True):
        segments.append(
            {
                "start": float(turn.start),
                "end": float(turn.end),
                "start_ms": int(turn.start * 1000),
                "end_ms": int(turn.end * 1000),
                "speaker": str(speaker),
            }
        )
    json.dump({"segments": segments}, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
