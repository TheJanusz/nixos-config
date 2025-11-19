{ config, lib, pkgs, ... }:

let  
  #config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) ["steam" "steam-unwrapped"];
in
{
  programs.gamescope = {
    enable = true;
    capSysNice = true;
  };
  programs.steam = {
    enable = true;
    gamescopeSession = {
      enable = true;
    };
    remotePlay.openFirewall = true;
  };

  environment.systemPackages = with pkgs; [
    unstable.heroic
    unstable.lutris
  ];
}

