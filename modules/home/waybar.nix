{ config, pkgs, ... }:
{
  home.packages = [ pkgs.pwvucontrol ];
  programs.waybar = {
    enable = true;
    settings = [{
      "hyprland/workspaces" = {
        all-outputs = false;
        persistent-only = false;
        format = "{id}";
        sort-by = "id";
      };
      modules-left = [
        "hyprland/workspaces"
      ];
      modules-center = [ "hyprland/window" ];
      modules-right = [
        "tray"
	# "network"
	# "backlight"
	"pulseaudio"
	# "battery"
	"clock"
      ];
      # network = {
      #   format = "󰖩 {essid}";
      #   format-disconnected = "󰖩 disconnected";
      # };
      pulseaudio = {
        on-click = "pwvucontrol";
      };
      clock = {
        format = "{:%a, %d %b  %H:%M}";
        tooltip-format = "{:%A, %d %B %Y}";
        locale = "pl_PL.UTF-8";
      };
    }];
  };
}

