# English subtitle + EN→PL translation + offline XTTS lektor (subpipe).
#
# Usage:
#   subpipe run /path/to/video.mkv
#   # → {stem}.subpipe/ with en.ass + context.json
#
#   subpipe analyze ./video.mkv
#   # → emotion / delivery / prosody on each cue (before translate)
#
#   subpipe translate ./video.mkv --mode draft
#   subpipe review ./video.mkv
#   subpipe translate ./video.mkv --mode apply
#
#   subpipe lektor init ./video.mkv --reference ~/voices/house.wav
#   subpipe lektor ./video.mkv              # TUI: preview / edit lektor_line / speed
#   subpipe lektor generate ./video.mkv     # → {stem}.subpipe/lektor/*.wav
#
# Models:
#   Whisper: ggml-large-v3-turbo (pinned in packages/subpipe/default.nix)
#   Translate/Analyze: Bielik-11B-v2.6-Instruct Q4_K_M (pinned; ~10 GiB VRAM target)
#   Lektor: Coqui XTTS-v2 via packages/subpipe/xtts_worker.py (first run downloads weights).
#   CPML license: COQUI_TOS_AGREED=1 is set by default (non-commercial CPML); commercial use needs a Coqui license.
#
# Lektor voice design:
#   Timbre/identity = reference.wav (6–30s clean mono speech), not a text prompt.
#   Delivery = voice.json speed + delivery_defaults (whisper/shout/rushed/…) mapped from analyze tags.
#   XTTS sampling (hardcoded in xtts_worker): temperature=0.75 top_p=0.85 top_k=50 repetition_penalty=5.
#   Per-cue spoken text = lektor_line if set, else text_pl.
#   Worker loads XTTS once, caches speaker conditioning latents, skips silence/unchanged cues.
#
# VRAM / better models (upgrade path):
#   Current pin targets ~10 GiB VRAM (Q4_K_M Bielik-11B + short per-cue context).
#   When the machine has ≥32 GiB VRAM, consider swapping SUBPIPE_TRANSLATE_MODEL to:
#     - Bielik-11B Q8_0 or fp16 (same family, higher fidelity)
#     - Bielik-v3 / newer SpeakLeash instruct releases when available
#     - PLLuM chat GGUFs (Polish gov models) at Q5/Q6 if quality wins on media text
#     - Qwen2.5/Qwen3 32B-Instruct Q4/Q5 for stronger multilingual + glossary obedience
#   Keep the Ruby prompt/schema stable; only change the pinned GGUF hash/URL.
#   XTTS-v2 typically wants a free GPU alongside or after LLM stages (not concurrent).
#
# Analyze stage (emotion for translate + lektor delivery speed):
#   Uses ffmpeg volumedetect on each cue slice + the same LLM for emotion/delivery labels.
#
# Future: specialized terminology lookup (e.g. automotive shows):
#   Prefer durable show vocab (subpipe vocab init/add/promote) for recurring
#   quirks like motor≠motocykl. Optional later: search/RAG over a pinned term corpus.
# Future: mix lektor/*.wav under the MKV (ffmpeg ducking / mux) — out of scope for v1.
#
# Overrides:
#   SUBPIPE_WHISPER_MODEL, SUBPIPE_TRANSLATE_MODEL, SUBPIPE_WHISPER_BIN, SUBPIPE_LLAMA_BIN
#   SUBPIPE_XTTS_WORKER, SUBPIPE_XTTS_MODEL, SUBPIPE_XTTS_DEVICE (cuda|cpu), SUBPIPE_XTTS_HOOK
#
# CUDA builds need unfree CUDA (host: modules/system/nvidia.nix).
# Set cudaSupport = false for CPU-only / non-NVIDIA machines.
#
# Coqui TTS: pin from nixpkgs stable (Python 3.13). Unstable's python3.14 breaks
# tensorflow-bin, which coqui-tts still pulls in.
{ pkgs, pkgs-stable, ... }:

let
  subpipe = pkgs.callPackage ../../packages/subpipe {
    cudaSupport = true;
    tts = pkgs-stable.tts;
  };
in
{
  home.packages = [
    subpipe
    # Also provided by ripping.nix / ai.nix; listed so this module is self-contained.
    pkgs.ffmpeg-full
    pkgs.mkvtoolnix
    pkgs.llama-cpp
  ];
}
