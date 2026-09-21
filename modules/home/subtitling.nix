# English subtitle + EN→PL translation + offline lektor (subpipe).
#
#   subpipe review ./ep.subpipe   # Neovim cue-list mentor
#
# PATH `subpipe` runs Ruby/Lua from this checkout; workers/models from the nix
# package via share/subpipe/env.sh (per-step defaults; override models freely).
#
# Enable with: subtitling.enable = true;
{ config, pkgs, pkgs-stable, lib, ... }:

let
  cfg = config.subtitling;
in
{
  options.subtitling.enable = lib.mkEnableOption "subpipe (EN→PL subtitling / lektor) and its dependencies";

  config = lib.mkIf cfg.enable (
    let
      subpipePkg = pkgs.callPackage ../../packages/subpipe {
        cudaSupport = true;
        tts = pkgs-stable.tts;
        python3 = pkgs-stable.python3;
      };

      liveRoot = "${config.home.homeDirectory}/nixos-config/packages/subpipe";

      subpipe = pkgs.writeShellScriptBin "subpipe" ''
        set -euo pipefail
        # shellcheck disable=SC1091
        source ${subpipePkg}/share/subpipe/env.sh
        export SUBPIPE_NVIM_RTP=${lib.escapeShellArg "${liveRoot}/nvim/subpipe"}
        export SUBPIPE_BIN="$0"
        exec ${lib.getExe pkgs.ruby} -I ${lib.escapeShellArg "${liveRoot}/lib"} \
          ${lib.escapeShellArg "${liveRoot}/lib/cli.rb"} "$@"
      '';

      subpipeWorkers = pkgs.runCommand "subpipe-workers" { } ''
        mkdir -p $out/bin
        for b in subpipe-xtts-worker subpipe-orpheus-worker subpipe-orpheus-worker-cpu subpipe-orpheus-setup-cuda; do
          ln -s ${subpipePkg}/bin/$b $out/bin/$b
        done
      '';
    in
    {
      home.packages = [
        subpipe
        subpipeWorkers
        pkgs.ffmpeg-full
        pkgs.mkvtoolnix
        pkgs.llama-cpp
      ];
    }
  );
}
