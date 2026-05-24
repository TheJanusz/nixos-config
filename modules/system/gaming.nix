{ config, lib, pkgs, ... }:

let  
  cfg = config.gaming;
in
  {
    options.gaming.enable = lib.mkEnableOption "Add gaming launchers and related features (steam, heroic, lutris)";
    config = lib.mkIf cfg.enable {
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
        lutris
      ];
    };
  }

