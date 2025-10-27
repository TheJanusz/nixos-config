{ config, pkgs, ... }:
let
  #neovim = pkgs.neovim;
in
{
  #imports = [
  #];

  programs.waybar = {
    enable = true;
    settings = [{
      modules-left = [
        "hyprland/workspaces"
      ];
      modules-center = [ "hyprland/window" ];
      modules-right = [
        "tray"
	"network"
	"backlight"
	"pulseaudio"
	"battery"
	"clock"
      ];
      network = {
        format = "󰖩 {essid}";
        format-disconnected = "󰖩 disconnected";
      };
    }];
  };
}

