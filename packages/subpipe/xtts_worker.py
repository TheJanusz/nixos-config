#!/usr/bin/env python3
# Long-lived XTTS-v2 worker for subpipe lektor.
# Protocol: one JSON object per stdin line → one JSON object per stdout line.
# Commands: {"cmd":"ping"} | {"cmd":"load",...} | {"cmd":"synth",...} | {"cmd":"quit"}
#
# Compat: nixpkgs coqui-tts 0.26.x + transformers≥4.52/5 (garbled audio without GPT2InferenceModel fix).

from __future__ import annotations

import json
import os
import re
import sys
import traceback
import types
import wave
from pathlib import Path

# XTTS-v2 is under Coqui's CPML (non-commercial by default). Agree non-interactively
# so first-run download does not print a [y/n] prompt on stdout (breaks JSON-lines).
os.environ.setdefault("COQUI_TOS_AGREED", "1")


def _patch_transformers() -> None:
    """Make coqui-tts importable under transformers 5.x before any TTS import."""
    import torch
    import transformers
    import transformers.pytorch_utils as pu
    import transformers.generation.utils as gu
    from transformers import GenerationConfig

    if not hasattr(pu, "isin_mps_friendly"):
        pu.isin_mps_friendly = torch.isin

    # transformers 5 raises on missing GenerationConfig attrs; Coqui expects do_stream.
    if not getattr(GenerationConfig, "_subpipe_do_stream_patched", False):
        _orig_gc_init = GenerationConfig.__init__

        def _gc_init(self, *args, **kwargs):
            do_stream = kwargs.pop("do_stream", False)
            _orig_gc_init(self, *args, **kwargs)
            if not hasattr(self, "do_stream"):
                self.do_stream = do_stream

        GenerationConfig.__init__ = _gc_init  # type: ignore[method-assign]
        GenerationConfig._subpipe_do_stream_patched = True

    class _BeamStub:
        def __init__(self, *a, **k):
            raise RuntimeError(
                "beam search unavailable under this transformers version; use sampling"
            )

    for name in (
        "BeamSearchScorer",
        "ConstrainedBeamSearchScorer",
        "DisjunctiveConstraint",
        "PhrasalConstraint",
    ):
        if not hasattr(transformers, name) or getattr(transformers, name, None) is None:
            setattr(transformers, name, _BeamStub)

    if not hasattr(gu, "SampleOutput"):
        gu.SampleOutput = getattr(gu, "GenerateDecoderOnlyOutput", gu.GenerateOutput)

    # `from transformers import BeamSearchScorer` fails on LazyModule even after setattr
    # when done inside coqui's stream_generator. Preload a patched copy into sys.modules.
    sg_key = "TTS.tts.layers.xtts.stream_generator"
    gi_key = "TTS.tts.layers.xtts.gpt_inference"

    tts_xtts_dir = None
    search_roots = list(sys.path)
    try:
        import site as _site

        search_roots.extend(_site.getsitepackages())
        usp = _site.getusersitepackages()
        if usp:
            search_roots.append(usp)
    except Exception:
        pass

    for p in search_roots:
        if not p:
            continue
        candidate = Path(p) / "TTS" / "tts" / "layers" / "xtts"
        if (candidate / "stream_generator.py").is_file():
            tts_xtts_dir = candidate
            break

    if tts_xtts_dir is None:
        return

    # Critical fix (coqui PR #414/#550): stock gpt_inference.prepare_inputs_for_generation
    # corrupts output under transformers>=4.52. Inject upstream-compatible module.
    if gi_key not in sys.modules:
        fixed_gi = Path(__file__).resolve().parent / "patches" / "gpt_inference.py"
        if fixed_gi.is_file():
            mod = types.ModuleType(gi_key)
            mod.__file__ = str(fixed_gi)
            exec(compile(fixed_gi.read_text(encoding="utf-8"), str(fixed_gi), "exec"), mod.__dict__)
            sys.modules[gi_key] = mod

    if sg_key in sys.modules:
        return

    tts_root = tts_xtts_dir / "stream_generator.py"
    src = tts_root.read_text(encoding="utf-8")
    # Avoid `from transformers import BeamSearchScorer` (LazyModule raises even after setattr).
    old = """from transformers import (
    BeamSearchScorer,
    ConstrainedBeamSearchScorer,
    DisjunctiveConstraint,
    GenerationConfig,
    GenerationMixin,
    LogitsProcessorList,
    PhrasalConstraint,
    PreTrainedModel,
    StoppingCriteriaList,
    TemperatureLogitsWarper,
    TopKLogitsWarper,
    TopPLogitsWarper,
)"""
    new = """from transformers import (
    GenerationConfig,
    GenerationMixin,
    LogitsProcessorList,
    PreTrainedModel,
    StoppingCriteriaList,
    TemperatureLogitsWarper,
    TopKLogitsWarper,
    TopPLogitsWarper,
)
# Injected by subpipe for transformers≥5 (symbols removed from public API).
BeamSearchScorer = _SUBPIPE_BEAM_STUB
ConstrainedBeamSearchScorer = _SUBPIPE_BEAM_STUB
DisjunctiveConstraint = _SUBPIPE_BEAM_STUB
PhrasalConstraint = _SUBPIPE_BEAM_STUB"""
    if old in src:
        src = src.replace(old, new)
    src = src.replace(
        "from transformers.generation.utils import GenerateOutput, SampleOutput, logger",
        "from transformers.generation.utils import GenerateOutput, logger\n"
        "SampleOutput = getattr(__import__('transformers.generation.utils', fromlist=['SampleOutput']), "
        "'SampleOutput', GenerateOutput)",
    )
    # Fix StreamGenerationConfig for transformers 5 (do_stream + from_model_config).
    old_sgc = """class StreamGenerationConfig(GenerationConfig):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.do_stream = kwargs.pop("do_stream", False)"""
    new_sgc = """class StreamGenerationConfig(GenerationConfig):
    def __init__(self, **kwargs):
        do_stream = kwargs.pop(\"do_stream\", False)
        super().__init__(**kwargs)
        self.do_stream = do_stream

    @classmethod
    def from_model_config(cls, model_config, **kwargs):
        do_stream = kwargs.pop(\"do_stream\", False)
        config = super().from_model_config(model_config)
        config.do_stream = do_stream
        return config"""
    if old_sgc in src:
        src = src.replace(old_sgc, new_sgc)
    mod = types.ModuleType(sg_key)
    mod.__file__ = str(tts_root)
    globs = mod.__dict__
    globs["_SUBPIPE_BEAM_STUB"] = _BeamStub
    exec(compile(src, str(tts_root), "exec"), globs)
    sys.modules[sg_key] = mod


def _bootstrap_tts():
    _patch_transformers()
    from TTS.api import TTS  # noqa: WPS612

    return TTS


MODEL_NAME = os.environ.get(
    "SUBPIPE_XTTS_MODEL", "tts_models/multilingual/multi-dataset/xtts_v2"
)

# Sampling knobs for slightly more natural/varied prosody than stock-safe defaults.
# (Coqui docs: lower top_p/top_k → more "likely"/flat; higher temperature → more variation.)
XTTS_INFERENCE_KWARGS = {
    "temperature": 0.75,
    "top_p": 0.85,
    "top_k": 50,
    "repetition_penalty": 5.0,
}

_state: dict = {
    "tts": None,
    "model": None,
    "ref": None,
    "language": "pl",
    "latents": None,  # (gpt_cond_latent, speaker_embedding) or None
    "latents_key": None,
    "device": None,
}


def reply(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def resolve_device() -> str:
    import torch

    env = os.environ.get("SUBPIPE_XTTS_DEVICE", "").strip()
    if env:
        return env
    return "cuda" if torch.cuda.is_available() else "cpu"


def ensure_loaded(language: str = "pl") -> None:
    if _state["tts"] is not None:
        _state["language"] = language or _state["language"]
        return
    device = resolve_device()
    _state["device"] = device
    reply({"ok": True, "event": "loading", "model": MODEL_NAME, "device": device})
    TTS = _bootstrap_tts()
    tts = TTS(MODEL_NAME, gpu=(device == "cuda"))
    _state["tts"] = tts
    _state["language"] = language or "pl"
    try:
        _state["model"] = tts.synthesizer.tts_model
    except Exception:
        _state["model"] = None
    reply({"ok": True, "event": "ready", "device": device})


def get_latents(speaker_wav: str):
    """Cache XTTS speaker conditioning for a reference WAV (mtime-aware)."""
    path = Path(speaker_wav)
    key = f"{path.resolve()}:{path.stat().st_mtime_ns}"
    if _state["latents"] is not None and _state["latents_key"] == key:
        return _state["latents"]

    model = _state["model"]
    if model is None or not hasattr(model, "get_conditioning_latents"):
        _state["latents"] = None
        _state["latents_key"] = key
        return None

    gpt_cond_latent, speaker_embedding = model.get_conditioning_latents(
        audio_path=[str(path)]
    )
    _state["latents"] = (gpt_cond_latent, speaker_embedding)
    _state["latents_key"] = key
    return _state["latents"]


def write_wav(path: str, samples, sample_rate: int) -> None:
    import numpy as np

    path = str(path)
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    audio = np.clip(np.asarray(samples, dtype=np.float32), -1.0, 1.0)
    pcm = (audio * 32767.0).astype(np.int16)
    with wave.open(path, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(int(sample_rate))
        wf.writeframes(pcm.tobytes())


def concat_wavs(paths: list[str], out_path: str) -> float:
    frames = []
    rate = None
    for p in paths:
        with wave.open(p, "rb") as wf:
            if rate is None:
                rate = wf.getframerate()
            elif wf.getframerate() != rate:
                raise RuntimeError(f"sample rate mismatch in {p}")
            frames.append(wf.readframes(wf.getnframes()))
    Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    data = b"".join(frames)
    with wave.open(out_path, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(rate or 24000)
        wf.writeframes(data)
    n = len(data) // 2
    return n / float(rate or 24000)


def sample_rate_of(tts) -> int:
    try:
        return int(tts.synthesizer.output_sample_rate)
    except Exception:
        return int(getattr(tts, "output_sample_rate", None) or 24000)


def synth_one(text: str, speaker_wav: str, language: str, speed: float, out_path: str) -> float:
    import numpy as np

    tts = _state["tts"]
    model = _state["model"]
    latents = get_latents(speaker_wav)
    sr = sample_rate_of(tts)

    if latents is not None and model is not None and hasattr(model, "inference"):
        gpt_cond_latent, speaker_embedding = latents
        # XTTS inference API (coqui): returns dict with "wav"
        out = model.inference(
            text,
            language,
            gpt_cond_latent,
            speaker_embedding,
            speed=float(speed) if speed else 1.0,
            **XTTS_INFERENCE_KWARGS,
        )
        if isinstance(out, dict):
            wav = out.get("wav", out.get("audio"))
        else:
            wav = out
        arr = np.asarray(wav, dtype=np.float32).reshape(-1)
        write_wav(out_path, arr, sr)
        return float(len(arr)) / float(sr)

    # Fallback: high-level API (reclones speaker each call)
    wav = tts.tts(
        text=text,
        speaker_wav=speaker_wav,
        language=language,
        speed=float(speed) if speed else 1.0,
        **XTTS_INFERENCE_KWARGS,
    )
    arr = np.asarray(wav, dtype=np.float32).reshape(-1)
    write_wav(out_path, arr, sr)
    return float(len(arr)) / float(sr)


def chunk_text(text: str, limit: int = 220) -> list[str]:
    text = " ".join(text.split())
    if len(text) <= limit:
        return [text] if text else []
    parts: list[str] = []
    buf = ""
    pieces = re.split(r"(?<=[.!?…])\s+", text)
    for piece in pieces:
        if not piece:
            continue
        if not buf:
            buf = piece
        elif len(buf) + 1 + len(piece) <= limit:
            buf = f"{buf} {piece}"
        else:
            parts.append(buf)
            buf = piece
        while len(buf) > limit:
            parts.append(buf[:limit])
            buf = buf[limit:].lstrip()
    if buf:
        parts.append(buf)
    return parts


def handle(msg: dict) -> dict:
    cmd = msg.get("cmd")
    if cmd == "ping":
        return {
            "ok": True,
            "pong": True,
            "loaded": _state["tts"] is not None,
            "device": _state["device"] or resolve_device(),
            "latents_cached": _state["latents"] is not None,
        }
    if cmd == "quit":
        return {"ok": True, "bye": True}
    if cmd == "load":
        ensure_loaded(msg.get("language") or "pl")
        ref = msg.get("reference_wav")
        if ref:
            if not Path(ref).is_file():
                return {"ok": False, "error": f"reference_wav not found: {ref}"}
            _state["ref"] = ref
            try:
                get_latents(ref)
            except Exception as e:
                return {
                    "ok": False,
                    "error": f"speaker conditioning failed: {e}",
                    "trace": traceback.format_exc()[-2000:],
                }
        return {
            "ok": True,
            "loaded": True,
            "device": _state["device"],
            "reference_wav": _state["ref"],
            "latents_cached": _state["latents"] is not None,
        }
    if cmd == "synth":
        ensure_loaded(msg.get("language") or _state["language"])
        text = (msg.get("text") or "").strip()
        out_path = msg.get("out_path")
        ref = msg.get("reference_wav") or _state["ref"]
        language = msg.get("language") or _state["language"] or "pl"
        speed = float(msg.get("speed") or 1.0)
        if not text:
            return {"ok": False, "error": "empty text"}
        if not out_path:
            return {"ok": False, "error": "out_path required"}
        if not ref or not Path(ref).is_file():
            return {"ok": False, "error": f"reference_wav missing: {ref}"}
        _state["ref"] = ref
        chunks = chunk_text(text)
        if not chunks:
            return {"ok": False, "error": "empty text after normalize"}
        tmp_paths = []
        total_dur = 0.0
        try:
            for i, chunk in enumerate(chunks):
                part = f"{out_path}.part{i}.wav"
                dur = synth_one(chunk, ref, language, speed, part)
                total_dur += dur
                tmp_paths.append(part)
            if len(tmp_paths) == 1:
                Path(tmp_paths[0]).replace(out_path)
            else:
                concat_wavs(tmp_paths, out_path)
                for p in tmp_paths:
                    Path(p).unlink(missing_ok=True)
            return {
                "ok": True,
                "out_path": out_path,
                "duration_s": total_dur,
                "chunks": len(chunks),
                "latents_cached": _state["latents"] is not None,
            }
        except Exception as e:
            for p in tmp_paths:
                Path(p).unlink(missing_ok=True)
            return {"ok": False, "error": str(e), "trace": traceback.format_exc()[-2000:]}
    return {"ok": False, "error": f"unknown cmd: {cmd}"}


def main() -> None:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError as e:
            reply({"ok": False, "error": f"invalid JSON: {e}"})
            continue
        try:
            out = handle(msg)
        except Exception as e:
            out = {"ok": False, "error": str(e), "trace": traceback.format_exc()[-2000:]}
        reply(out)
        if msg.get("cmd") == "quit":
            break


if __name__ == "__main__":
    main()
