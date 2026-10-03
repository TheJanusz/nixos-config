{ config, pkgs, ... }:
let
  # 0.15.0 still sends legacy `dispatch workspace N`. Hyprland's Lua config
  # ignores that, so clicking a workspace number does nothing. This commit
  # sends hl.dsp.focus instead. Meson version stays 0.15.0.
  # cavaSupport stays off: this commit's libcava wrap expects cava 0.10.7,
  # while nixpkgs vendors 0.10.7-beta under a different subproject directory.
  # The bar config does not use the cava module.
  waybar = (pkgs.waybar.override { cavaSupport = false; }).overrideAttrs (old: {
    src = pkgs.fetchFromGitHub {
      owner = "Alexays";
      repo = "Waybar";
      rev = "74cf45d53017da6ab9ccf54b6740d488d2bfa977";
      hash = "sha256-CGhXAM1sbWFZCC6TA1GnD+cZ6Z8TgM/0xYYO4iLKn+c=";
    };
    # Nix enables auto features. This commit's WWAN module then requires
    # mm-glib, which the desktop package does not ship.
    mesonFlags = (old.mesonFlags or [ ]) ++ [ "-Dwwan=disabled" ];
  });
in
{
  programs.waybar = {
    enable = true;
    package = waybar;
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
      clock = {
        format = "{:%a, %d %b  %H:%M}";
        tooltip-format = "{:%A, %d %B %Y}";
        locale = "pl_PL.UTF-8";
      };
    }];
  };
}

