{
  lib,
  stdenvNoCC,
  ruby,
  makeWrapper,
  whisper-cpp,
  llama-cpp,
  ffmpeg,
  mkvtoolnix,
  fetchurl,
  tts,
  cudaSupport ? false,
}:

let
  whisperCpp =
    if cudaSupport then whisper-cpp.override { inherit cudaSupport; } else whisper-cpp;

  # Prefer CUDA llama.cpp when building for an NVIDIA host (same flag as whisper).
  llamaCpp =
    if cudaSupport then llama-cpp.override { inherit cudaSupport; } else llama-cpp;

  # ggml-large-v3-turbo from https://huggingface.co/ggerganov/whisper.cpp
  whisperModel = fetchurl {
    name = "ggml-large-v3-turbo.bin";
    url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin";
    hash = "sha256-H8cPd0046xaZk6w5Huo1fvR8iHV+9y7llDh5t+jivGk=";
  };

  # Bielik-11B-v2.6-Instruct Q4_K_M (~6.3 GiB weights).
  translateModel = fetchurl {
    name = "Bielik-11B-v2.6-Instruct.Q4_K_M.gguf";
    url = "https://huggingface.co/speakleash/Bielik-11B-v2.6-Instruct-GGUF/resolve/main/Bielik-11B-v2.6-Instruct.Q4_K_M.gguf";
    hash = "sha256-VQZTHjOF17uk9mfNTOn0BSRFBWcf4NkQI1H3gZW1bGI=";
  };
in
stdenvNoCC.mkDerivation {
  pname = "subpipe";
  version = "0.6.6";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [ ruby ];

  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/subpipe $out/bin
    cp -r lib/. $out/lib/subpipe/
    cp xtts_worker.py $out/lib/subpipe/xtts_worker.py
    mkdir -p $out/lib/subpipe/patches
    cp -r patches/. $out/lib/subpipe/patches/

    # Reuse coqui-tts Python + site-packages bootstrap (same as `tts` CLI).
    TTS_WRAPPED=${tts}/bin/.tts-wrapped
    TTS_PY=$(head -1 "$TTS_WRAPPED" | sed 's/^#!//')
    SITE_LIST=$(sed -n 's/.*functools\.reduce(lambda k, p: site\.addsitedir(p, k), \[\(.*\)\],.*/\1/p' "$TTS_WRAPPED")

    cat > $out/bin/subpipe-xtts-worker <<EOF
    #!$TTS_PY
    import sys, site, functools, runpy, os
    os.environ.setdefault("PYTHONNOUSERSITE", "true")
    functools.reduce(lambda k, p: site.addsitedir(p, k), [$SITE_LIST], site._init_pathinfo())
    sys.argv[0] = "$out/lib/subpipe/xtts_worker.py"
    runpy.run_path("$out/lib/subpipe/xtts_worker.py", run_name="__main__")
    EOF
    chmod +x $out/bin/subpipe-xtts-worker

    makeWrapper ${lib.getExe ruby} $out/bin/subpipe \
      --add-flags "$out/lib/subpipe/cli.rb" \
      --prefix PATH : ${
        lib.makeBinPath [
          whisperCpp
          llamaCpp
          ffmpeg
          mkvtoolnix
          tts
        ]
      } \
      --prefix PATH : $out/bin \
      --set-default SUBPIPE_WHISPER_MODEL ${whisperModel} \
      --set-default SUBPIPE_WHISPER_BIN ${lib.getExe' whisperCpp "whisper-cli"} \
      --set-default SUBPIPE_TRANSLATE_MODEL ${translateModel} \
      --set-default SUBPIPE_LLAMA_BIN ${lib.getExe' llamaCpp "llama-cli"} \
      --set-default SUBPIPE_LLAMA_SERVER_BIN ${lib.getExe' llamaCpp "llama-server"} \
      --set-default SUBPIPE_XTTS_WORKER $out/bin/subpipe-xtts-worker \
      --set-default COQUI_TOS_AGREED 1
    runHook postInstall
  '';

  meta = {
    description = "Video → English ASS + EN→PL translation + offline XTTS lektor";
    mainProgram = "subpipe";
    license = lib.licenses.mit;
  };
}
