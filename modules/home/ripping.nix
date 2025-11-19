{ config, lib, pkgs, ... }:

let
  # 2.9.3+ adds a fix for 1 track CD's, but it hasn't released yet
  abcdeOverlay = (final: prev: {
    abcde = if prev.abcde.version == "2.9.3" then
    prev.abcde.overrideAttrs (old: {
      version = "git";
      src = pkgs.fetchFromGitHub {
        owner = "glanois";
        repo = "abcde";
        rev = "516cfdc";
        sha256 = "sha256-bbPmw4r+CgNQT/Txz3a7Sk+WNDft6wM8Z6KVNZqijGY=";
      };
    })
    else prev.abcde;
  });
in
{  
  nixpkgs.overlays = [ abcdeOverlay ];
  home.packages = with pkgs; [
    abcde # CD ripping
    mkvtoolnix-cli # Mostly for editing chapter info
    picard # Adding stuff to MusicBrainz
    yt-dlp # Downloading stuff from video sites
  ];
}

