{ config, pkgs, ... }:
let
  #neovim = pkgs.neovim;
in
{
  home.packages = with pkgs; [
    grimblast # screenshots
  ];
  programs.kitty.enable = true;
  wayland.windowManager.hyprland.enable = true;
  wayland.windowManager.hyprland.settings = {
    bind = [
      "SUPER, F, exec, nautilus"
      "SUPER, B, exec, brave"
      "SUPER, RETURN, exec, kitty"
      "SUPER, W, killactive"
      "SUPER, M, exec, kitty -e btop"
      "SUPER, O, exec, obsidian"
      "SUPER, N, exec, nvim"
      "SUPER, D, exec, discord"
      "SUPER, P, exec, bitwarden"
      "SUPER, R, exec, rofi -show run"
      # Moving window focus
      "SUPER, H, movefocus, l"
      "SUPER, J, movefocus, d"
      "SUPER, K, movefocus, u"
      "SUPER, L, movefocus, r"
      # "SUPER Shift, G, tagwindow, +game"
      "SUPER Shift, H, movewindow, l"
      "SUPER Shift, J, movewindow, d"
      "SUPER Shift, K, movewindow, u"
      "SUPER Shift, L, movewindow, r"
      
      "SUPER Shift, left, workspace, r-1"
      "SUPER Shift, right, workspace, r+1"
      "SUPER Shift, Q, movetoworkspace, r-1"
      "SUPER Shift, E, movetoworkspace, r+1"
      "SUPER Shift, F, fullscreen"
      # Screenshots
      "SUPER Shift, A, exec, grimblast copysave area"
      "SUPER Shift, W, exec, grimblast copysave active"
    ];
    bindle = [
      ",XF86AudioRaiseVolume, exec, wpctl set-volume -l 1.5 @DEFAULT_SINK@ 5%+"
      ",XF86AudioLowerVolume, exec, wpctl set-volume -l 1.5 @DEFAULT_SINK@ 5%-"
    ];
    bindl = [
      ",XF86AudioMicMute, exec, wpctl set-mute @DEFAULT_SOURCE@ toggle"
      ",XF86AudioMute, exec, wpctl set-mute @DEFAULT_SINK@ toggle"
    ];
    exec-once = ["waybar"];
    general = {
      "col.active_border" = "rgb(0,141,79)";
      gaps_in = 2;
      gaps_out = 4;
    };
    gesture = [
      "3, horizontal, workspace"
    ];
    input = {
      kb_layout = "pl";
      natural_scroll = false;
    };
    monitor = [
      "HDMI-A-2,3840x2160@60,-1920x0,2"
      "DP-4, 2560x1440@60,0x0,1,transform,3"
      "DP-5, 2560x1440@60,1440x0,1"
      "Unknown-1,disabled"
    ];
    decoration = {
      rounding = 5;
    };
    windowrule = [
      "opacity 1.0 0.8,class:.+"
      # "fullscreen, 0, tag:game"
      # "immediate, tag:game"
    ];
  };

  wayland.windowManager.hyprland.plugins = [];
}
