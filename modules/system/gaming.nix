{ config, lib, pkgs, ... }:

let  
in
{
  multipleAllowedUnfreePredicate = [
    "steam"
    "steam-unwrapped"
  ];

  programs.gamescope = {
    enable = true;
    capSysNice = true;
  };
  programs.steam = {
    enable = true;
    package = pkgs.unstable.steam;
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

