{ config, lib, pkgs, ... }:

let  
in
{  
  home.packages = with pkgs; [
    abcde # CD ripping
    yt-dlp # Downloading stuff from video sites
  ];
}

