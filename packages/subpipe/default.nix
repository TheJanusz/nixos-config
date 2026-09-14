{
  lib,
  stdenvNoCC,
  bash,
  gcc,
  zlib,
  ruby,
  makeWrapper,
  whisper-cpp,
  llama-cpp,
  ffmpeg,
  mkvtoolnix,
  fetchurl,
  fetchPypi,
  python3,
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

  # Orpheus PL worker: transformers + SNAC (not the Coqui TTS env).
  # Default Nix env is CPU torch (CUDA torch in nixpkgs rebuilds Magma/bindings).
  # Prefer a user venv from `subpipe-orpheus-setup-cuda` (official cu128 wheels) when present.
  orpheusPython = python3.override {
    packageOverrides = self: super: {
      snac = self.buildPythonPackage {
        pname = "snac";
        version = "1.2.1";
        format = "wheel";
        src = fetchPypi {
          pname = "snac";
          version = "1.2.1";
          format = "wheel";
          python = "py3";
          dist = "py3";
          hash = "sha256-lvkOIhEhrQPW47Bgp4cmix79vkJFYKWPb3Mt9tSRTcc=";
        };
        propagatedBuildInputs = [
          self.torch
          self.numpy
          self.einops
          self.huggingface-hub
        ];
        dontBuild = true;
        doCheck = false;
        pythonImportsCheck = [ "snac" ];
      };
    };
  };

  orpheusEnv = orpheusPython.withPackages (
    ps: with ps; [
      torch
      transformers
      accelerate
      numpy
      einops
      huggingface-hub
      snac
      soundfile
    ]
  );

  # Pip CUDA wheels need libstdc++ / zlib from Nix; driver from /run/opengl-driver.
  orpheusLdPath = lib.makeLibraryPath [
    gcc.cc.lib
    zlib
  ];

  toolPath = lib.makeBinPath [
    whisperCpp
    llamaCpp
    ffmpeg
    mkvtoolnix
    tts
  ];
in
stdenvNoCC.mkDerivation {
  pname = "subpipe";
  version = "0.12.1";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [ ruby ];

  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/subpipe $out/bin
    cp -r lib/. $out/lib/subpipe/
    cp -r nvim $out/lib/subpipe/nvim
    cp xtts_worker.py $out/lib/subpipe/xtts_worker.py
    cp orpheus_worker.py $out/lib/subpipe/orpheus_worker.py
    cp diarize_worker.py $out/lib/subpipe/diarize_worker.py
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

    cp orpheus_cuda_setup.sh $out/lib/subpipe/orpheus_cuda_setup.sh
    cp orpheus_worker.sh $out/lib/subpipe/orpheus_worker.sh
    chmod +x $out/lib/subpipe/orpheus_cuda_setup.sh $out/lib/subpipe/orpheus_worker.sh

    # CPU fallback (Nix torch).
    cat > $out/bin/subpipe-orpheus-worker-cpu <<EOF
    #!${orpheusEnv.interpreter}
    import runpy, os, sys
    os.environ.setdefault("PYTHONNOUSERSITE", "true")
    sys.argv[0] = "$out/lib/subpipe/orpheus_worker.py"
    runpy.run_path("$out/lib/subpipe/orpheus_worker.py", run_name="__main__")
    EOF
    chmod +x $out/bin/subpipe-orpheus-worker-cpu

    # Prefer CUDA wheel venv when present; else CPU.
    makeWrapper ${bash}/bin/bash $out/bin/subpipe-orpheus-worker \
      --add-flags "$out/lib/subpipe/orpheus_worker.sh" \
      --set SUBPIPE_ORPHEUS_WORKER_PY $out/lib/subpipe/orpheus_worker.py \
      --set SUBPIPE_ORPHEUS_WORKER_CPU $out/bin/subpipe-orpheus-worker-cpu \
      --prefix LD_LIBRARY_PATH : "${orpheusLdPath}:/run/opengl-driver/lib"

    makeWrapper $out/lib/subpipe/orpheus_cuda_setup.sh $out/bin/subpipe-orpheus-setup-cuda \
      --prefix PATH : ${lib.makeBinPath [ bash ]} \
      --prefix LD_LIBRARY_PATH : "${orpheusLdPath}:/run/opengl-driver/lib" \
      --set-default SUBPIPE_ORPHEUS_BOOTSTRAP_PYTHON ${orpheusEnv.interpreter}

    # Shared per-step defaults for store + live (subtitling.nix) wrappers.
    # Future hooks (do not implement here): SUBPIPE_REFLECT_MODEL, SUBPIPE_TTS_ENGINE
    mkdir -p $out/share/subpipe
    cat > $out/share/subpipe/env.sh <<EOF
# subpipe per-step defaults — source then optionally override SUBPIPE_NVIM_RTP / SUBPIPE_BIN
export PATH=${lib.escapeShellArg toolPath}:$out/bin''${PATH:+:}''$PATH
export SUBPIPE_WHISPER_MODEL=${lib.escapeShellArg whisperModel}
export SUBPIPE_WHISPER_BIN=${lib.escapeShellArg (lib.getExe' whisperCpp "whisper-cli")}
export SUBPIPE_TRANSLATE_MODEL=${lib.escapeShellArg translateModel}
export SUBPIPE_LLAMA_BIN=${lib.escapeShellArg (lib.getExe' llamaCpp "llama-cli")}
export SUBPIPE_LLAMA_SERVER_BIN=${lib.escapeShellArg (lib.getExe' llamaCpp "llama-server")}
export SUBPIPE_XTTS_WORKER=$out/bin/subpipe-xtts-worker
export SUBPIPE_ORPHEUS_WORKER=$out/bin/subpipe-orpheus-worker
export SUBPIPE_ORPHEUS_MODEL=TeeZee/Orpheus-TTS-pl-v2.5
export SUBPIPE_DIARIZE_WORKER=$out/lib/subpipe/diarize_worker.py
export SUBPIPE_NVIM_RTP=''${SUBPIPE_NVIM_RTP:-$out/lib/subpipe/nvim/subpipe}
export COQUI_TOS_AGREED=1
EOF

    makeWrapper ${lib.getExe ruby} $out/bin/subpipe \
      --add-flags "$out/lib/subpipe/cli.rb" \
      --run "source $out/share/subpipe/env.sh"
    runHook postInstall
  '';

  meta = {
    description = "Video → English ASS + EN→PL translation + mentor nvim plugin + offline Orpheus/XTTS lektor";
    mainProgram = "subpipe";
    license = lib.licenses.mit;
  };
}
