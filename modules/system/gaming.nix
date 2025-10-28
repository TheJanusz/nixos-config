{ config, lib, pkgs, ... }:

let  
  #config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) ["steam" "steam-unwrapped"];
in
{
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
  };

  environment.systemPackages = with pkgs; [
    heroic
    lutris
  ];
}

