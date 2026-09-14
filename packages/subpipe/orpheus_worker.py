#!/usr/bin/env python3
# Long-lived Orpheus TTS worker for subpipe lektor (Polish community finetune).
# Protocol: one JSON object per stdin line → one JSON object per stdout line.
# Commands: {"cmd":"ping"} | {"cmd":"load",...} | {"cmd":"synth",...} | {"cmd":"quit"}
#
# Default model: TeeZee/Orpheus-TTS-pl-v2.5 (Common Voice PL). Voices e.g. tomasz, jan, …

from __future__ import annotations

import json
import os
import sys
import traceback
import wave
from pathlib import Path

MODEL_NAME = os.environ.get("SUBPIPE_ORPHEUS_MODEL", "TeeZee/Orpheus-TTS-pl-v2.5")
SNAC_MODEL = os.environ.get("SUBPIPE_SNAC_MODEL", "hubertsiuzdak/snac_24khz")
SAMPLE_RATE = 24000

# Orpheus special token IDs (Canopy / Unsloth layout).
TOK_SOH = 128259
TOK_EOT = 128009
TOK_EOH = 128260
TOK_SOS = 128261  # start-of-speech (Canopy prompt trailer)
TOK_EOS = 128258
TOK_AUDIO_END = 128257
TOK_AUDIO_CODE_BASE = 128266

# v2.5 Common Voice PL speakers (subset of popular narrator-ish male/female).
# Full list is large; unknown voices are still attempted.
ORPHEUS_VOICES = (
    "tomasz",
    "jan",
    "konrad",
    "wojciech",
    "krystian",
    "marek",
    "emilia",
    "kinga",
    "milena",
    "weronika",
    # Legacy TeeZee v2.0 names (still work if SUBPIPE_ORPHEUS_MODEL=v2.0)
    "bartek",
    "ola",
    "radek",
    "aga",
    "monika",
    "darek",
    "sylwia",
    "kuba",
)

# Canopy Orpheus defaults (engine_class.generate_tokens_sync).
GEN_KWARGS = {
    "temperature": 0.7,
    "top_p": 0.85,
    "repetition_penalty": 1.35,
    "do_sample": True,
}

_state: dict = {
    "model": None,
    "tokenizer": None,
    "snac": None,
    "device": None,
    "voice": "tomasz",
    "language": "pl",
    "model_name": MODEL_NAME,
}


def reply(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def resolve_device() -> str:
    import torch

    env = os.environ.get("SUBPIPE_ORPHEUS_DEVICE", "").strip()
    if env:
        return env
    return "cuda" if torch.cuda.is_available() else "cpu"


def write_wav(path: str, samples, sample_rate: int = SAMPLE_RATE) -> None:
    import numpy as np

    path = str(path)
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    audio = np.clip(np.asarray(samples, dtype=np.float32).reshape(-1), -1.0, 1.0)
    pcm = (audio * 32767.0).astype(np.int16)
    with wave.open(path, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(int(sample_rate))
        wf.writeframes(pcm.tobytes())


def _from_pretrained(loader, name: str, **kwargs):
    """Prefer HF cache only — avoids Hub auth/rate-limit checks when warm."""
    try:
        return loader(name, local_files_only=True, **kwargs)
    except Exception:
        return loader(name, **kwargs)


def ensure_loaded(voice: str | None = None, model_name: str | None = None) -> None:
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer
    from snac import SNAC

    if voice:
        _state["voice"] = voice
    if model_name:
        model_name = model_name.strip()
        if model_name and model_name != _state.get("model_name"):
            _state["model"] = None
            _state["tokenizer"] = None
            _state["snac"] = None
            _state["model_name"] = model_name

    if _state["model"] is not None:
        return

    name = _state.get("model_name") or MODEL_NAME
    device = resolve_device()
    _state["device"] = device
    reply({"ok": True, "event": "loading", "model": name, "device": device})

    dtype = torch.float16 if device == "cuda" else torch.float32
    tokenizer = _from_pretrained(AutoTokenizer.from_pretrained, name)
    model = _from_pretrained(
        AutoModelForCausalLM.from_pretrained,
        name,
        dtype=dtype,
        low_cpu_mem_usage=True,
    )
    model.eval()
    model.to(device)

    snac = _from_pretrained(SNAC.from_pretrained, SNAC_MODEL).eval()
    snac.to(device)

    _state["tokenizer"] = tokenizer
    _state["model"] = model
    _state["snac"] = snac
    reply({"ok": True, "event": "ready", "device": device, "voices": list(ORPHEUS_VOICES)})


def decode_snac(code_list: list[int]):
    """Convert flat Orpheus audio codes (per-slot offsets removed) to waveform."""
    import torch

    if len(code_list) < 7:
        return None
    n = (len(code_list) // 7) * 7
    code_list = code_list[:n]
    # Values must be in [0, 4095] for SNAC codebooks.
    if any(c < 0 or c > 4095 for c in code_list):
        return None

    device = _state["device"]
    snac = _state["snac"]

    codes_0, codes_1, codes_2 = [], [], []
    for i in range(0, n, 7):
        codes_0.append(code_list[i])
        codes_1.append(code_list[i + 1])
        codes_1.append(code_list[i + 4])
        codes_2.append(code_list[i + 2])
        codes_2.append(code_list[i + 3])
        codes_2.append(code_list[i + 5])
        codes_2.append(code_list[i + 6])

    codes = [
        torch.tensor(codes_0, device=device, dtype=torch.int32).unsqueeze(0),
        torch.tensor(codes_1, device=device, dtype=torch.int32).unsqueeze(0),
        torch.tensor(codes_2, device=device, dtype=torch.int32).unsqueeze(0),
    ]

    with torch.inference_mode():
        audio_hat = snac.decode(codes)
    audio = audio_hat.detach().float().cpu().squeeze()
    if audio.dim() > 1:
        audio = audio.reshape(-1)
    return audio.numpy()


def extract_snac_codes(token_ids: list[int]) -> list[int]:
    """Pull SNAC codebook indices from Orpheus LM token ids.

    Each audio token encodes its frame slot in the high bits
    ((id - BASE) // 4096 ∈ 0..6). We walk tokens in order and only commit
    complete 0..6 frames, resyncing on slot 0 if the stream skips.
    """
    cut = list(token_ids)
    if TOK_AUDIO_END in cut:
        cut = cut[cut.index(TOK_AUDIO_END) + 1 :]
    if TOK_EOS in cut:
        cut = cut[: cut.index(TOK_EOS)]

    codes: list[int] = []
    expect = 0
    frame: list[int] = []

    for t in cut:
        if not (TOK_AUDIO_CODE_BASE <= t < TOK_AUDIO_CODE_BASE + 7 * 4096):
            frame = []
            expect = 0
            continue

        raw = t - TOK_AUDIO_CODE_BASE
        slot = raw // 4096
        code = raw % 4096

        if slot != expect:
            if slot == 0:
                frame = [code]
                expect = 1
            else:
                frame = []
                expect = 0
            continue

        frame.append(code)
        if expect == 6:
            codes.extend(frame)
            frame = []
            expect = 0
        else:
            expect += 1

    return codes


def synth_one(text: str, voice: str, out_path: str, gen_kwargs: dict | None = None) -> float:
    import torch

    ensure_loaded(voice)
    model = _state["model"]
    tokenizer = _state["tokenizer"]
    device = _state["device"]

    prompt = f"{voice}: {text}"
    input_ids = tokenizer(prompt, return_tensors="pt").input_ids.to(device)
    # Canopy layout: SOH + text + EOT + EOH + SOS + AUDIO_END, then generate codes.
    start = torch.tensor([[TOK_SOH]], dtype=torch.long, device=device)
    end = torch.tensor(
        [[TOK_EOT, TOK_EOH, TOK_SOS, TOK_AUDIO_END]],
        dtype=torch.long,
        device=device,
    )
    input_ids = torch.cat([start, input_ids, end], dim=1)

    # ~7 SNAC codes per short phoneme budget; cap for cue-length lines.
    max_new = min(max(int(len(text) * 1.5) * 7 + 28, 140), 1200)
    kwargs = merge_gen_kwargs(gen_kwargs)

    with torch.inference_mode():
        generated = model.generate(
            input_ids=input_ids,
            attention_mask=torch.ones_like(input_ids),
            max_new_tokens=max_new,
            eos_token_id=TOK_EOS,
            pad_token_id=tokenizer.eos_token_id or TOK_EOS,
            **kwargs,
        )

    gen = generated[0, input_ids.shape[1] :].tolist()
    codes = extract_snac_codes(gen)
    if not codes:
        raise RuntimeError("Orpheus produced no audio tokens")

    audio = decode_snac(codes)
    if audio is None or len(audio) == 0:
        raise RuntimeError(
            f"SNAC decode failed (n_codes={len(codes)}, "
            f"minmax=({min(codes)},{max(codes)}))"
        )

    write_wav(out_path, audio, SAMPLE_RATE)
    return float(len(audio)) / float(SAMPLE_RATE)


def _clamp(val, lo: float, hi: float, default: float) -> float:
    try:
        f = float(val)
    except (TypeError, ValueError):
        f = default
    return max(lo, min(hi, f))


def merge_gen_kwargs(overrides: dict | None) -> dict:
    out = dict(GEN_KWARGS)
    if not overrides:
        return out
    if "temperature" in overrides and overrides["temperature"] is not None:
        out["temperature"] = _clamp(overrides["temperature"], 0.2, 1.5, 0.7)
    if "top_p" in overrides and overrides["top_p"] is not None:
        out["top_p"] = _clamp(overrides["top_p"], 0.1, 1.0, 0.85)
    if "repetition_penalty" in overrides and overrides["repetition_penalty"] is not None:
        out["repetition_penalty"] = _clamp(overrides["repetition_penalty"], 1.1, 1.8, 1.35)
    return out


def handle(msg: dict) -> dict:
    cmd = msg.get("cmd")
    if cmd == "ping":
        return {
            "ok": True,
            "pong": True,
            "loaded": _state["model"] is not None,
            "device": _state["device"] or resolve_device(),
            "engine": "orpheus_pl",
            "voice": _state["voice"],
        }
    if cmd == "quit":
        return {"ok": True, "bye": True}
    if cmd == "load":
        voice = (msg.get("voice") or _state["voice"] or "tomasz").strip().lower()
        model_name = (msg.get("model") or "").strip() or None
        if voice not in ORPHEUS_VOICES:
            # Allow unknown voices (finetune may add more); warn via stderr.
            print(f"orpheus: unknown voice {voice!r}; trying anyway", file=sys.stderr)
        try:
            ensure_loaded(voice, model_name=model_name)
        except Exception as e:
            return {
                "ok": False,
                "error": f"orpheus load failed: {e}",
                "trace": traceback.format_exc()[-2000:],
            }
        _state["language"] = msg.get("language") or "pl"
        return {
            "ok": True,
            "loaded": True,
            "device": _state["device"],
            "engine": "orpheus_pl",
            "voice": _state["voice"],
            "model": _state.get("model_name") or MODEL_NAME,
        }
    if cmd == "synth":
        text = (msg.get("text") or "").strip()
        out_path = msg.get("out_path")
        voice = (msg.get("voice") or _state["voice"] or "tomasz").strip().lower()
        if not text:
            return {"ok": False, "error": "empty text"}
        if not out_path:
            return {"ok": False, "error": "out_path required"}
        overrides = {
            "temperature": msg.get("temperature"),
            "top_p": msg.get("top_p"),
            "repetition_penalty": msg.get("repetition_penalty"),
        }
        try:
            ensure_loaded(voice)
            dur = synth_one(text, voice, out_path, gen_kwargs=overrides)
            return {
                "ok": True,
                "out_path": out_path,
                "duration_s": dur,
                "chunks": 1,
                "engine": "orpheus_pl",
                "voice": voice,
                "orpheus": merge_gen_kwargs(overrides),
            }
        except Exception as e:
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
