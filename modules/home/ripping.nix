{ config, lib, pkgs, ... }:

let
  # libblurayAACS = pkgs.libbluray.override {
  #   withAACS = true;
  #   withBDplus = true;
  # };
  # customFFMPEG = pkgs.ffmpeg-full.override { libbluray = libblurayAACS; };
  # customVLC = pkgs.vlc.override { libbluray-full = libblurayAACS; };
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
  vlcOverlay = (final: prev: {
    customLibbluray = prev.libbluray.override {
      withAACS = true;
      withBDplus = true;
      withJava = true;
    };
    customvlc = prev.vlc.override { libbluray-full = final.customLibbluray; };
    # customffmpeg = prev.ffmpeg.override { libbluray = final.customLibbluray; };
  });
in
{  
  nixpkgs.overlays = [ abcdeOverlay vlcOverlay ];
  home.packages = with pkgs; [
    abcde # CD ripping
    ffmpeg-full
    customvlc
    makemkv
    libaacs
    mkvtoolnix # Mostly for editing chapter info. Also ripping problematic titles from badly authored dvds
    picard # Adding stuff to MusicBrainz
    yt-dlp # Downloading stuff from video sites
  ];
}

