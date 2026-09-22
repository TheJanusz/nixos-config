{ config, pkgs, lib, ... }:
let
  inherit (lib.generators) mkLuaInline;
  bind = keys: dsp: flags: {
    _args = [ keys (mkLuaInline dsp) ] ++ lib.optional (flags != { }) flags;
  };
  modKey = rest: mkLuaInline ''mod .. " + ${rest}"'';
  # The rows layout treats left/right as up/down. On a portrait monitor,
  # those keys should cross to the neighboring screen instead.
  cross = action: direction: mon: ''
    function()
      local ws = hl.get_active_workspace()
      local monitor = ws and ws.monitor
      if monitor and (monitor.transform % 2 == 1) then
        hl.dispatch(${action}({ monitor = "${mon}" }))
      else
        hl.dispatch(${action}({ direction = "${direction}" }))
      end
    end
  '';
  # Not in nixpkgs. One MIT Python script; hyprctl comes from the system Hyprland.
  hypr-session-restore = pkgs.stdenvNoCC.mkDerivation {
    pname = "hypr-session-restore";
    version = "0-unstable-2026-06-11";
    src = pkgs.fetchFromGitHub {
      owner = "UpayanChatterjee";
      repo = "hypr-session-restore";
      rev = "d281be7fb5153e1a656d95263b349b93a7301aa7";
      hash = "sha256-2CQivm+knWyh+Umv3EEQcs3pFXAwfdlKbdFE/ABqiio=";
    };
    dontBuild = true;
    installPhase = ''
      install -Dm755 hypr-session-restore $out/bin/hypr-session-restore
      substituteInPlace $out/bin/hypr-session-restore \
        --replace-fail '#!/usr/bin/env python3' '#!${pkgs.python3}/bin/python3'
    '';
  };
in
{
  home.packages = [
    pkgs.grimblast # screenshots
    hypr-session-restore
  ];
  # Official TTY launcher starts the watchdog; the raw Hyprland binary warns.
  home.shellAliases.Hyprland = "start-hyprland";
  programs.kitty.enable = true;
  wayland.windowManager.hyprland.enable = true;
  wayland.windowManager.hyprland.configType = "lua";
  wayland.windowManager.hyprland.package = null;
  wayland.windowManager.hyprland.portalPackage = null;
  wayland.windowManager.hyprland.settings = {
    mod = {
      _var = "SUPER";
    };
    config = {
      general = {
        "col.active_border" = "rgb(0,141,79)";
        gaps_in = 2;
        gaps_out = 4;
      };
      input = {
        kb_layout = "pl";
        natural_scroll = false;
      };
      decoration = {
        rounding = 5;
      };
      dwindle = {
        split_width_multiplier = 1;
        preserve_split = false;
        permanent_direction_override = false;
      };
    };
    monitor = [
      {
        output = "HDMI-A-2";
        mode = "3840x2160@60";
        position = "-1920x0";
        scale = 2;
      }
      {
        output = "DP-3";
        mode = "2560x1440@120";
        position = "1440x0";
        scale = 1;
      }
      {
        output = "DP-4";
        mode = "2560x1440@60";
        position = "0x0";
        scale = 1;
        transform = 3;
      }
      {
        output = "Unknown-1";
        disabled = true;
      }
    ];
    gesture = {
      fingers = 3;
      direction = "horizontal";
      action = "workspace";
    };
    on = {
      _args = [
        "hyprland.start"
        (mkLuaInline ''
          function()
            hl.exec_cmd("waybar")
            hl.exec_cmd("sh -c 'sleep 2 && hypr-session-restore restore'")
            hl.exec_cmd("sh -c 'pgrep -f \"[h]ypr-session-restore daemon\" >/dev/null || hypr-session-restore daemon'")
          end
        '')
      ];
    };
    bind = [
      (bind (modKey "F") ''hl.dsp.exec_cmd("nautilus")'' { })
      (bind (modKey "B") ''hl.dsp.exec_cmd("brave")'' { })
      (bind (modKey "RETURN") ''hl.dsp.exec_cmd("kitty")'' { })
      (bind (modKey "W") "hl.dsp.window.close()" { })
      (bind (modKey "M") ''hl.dsp.exec_cmd("kitty -e btop")'' { })
      (bind (modKey "O") ''hl.dsp.exec_cmd("obsidian")'' { })
      (bind (modKey "D") ''hl.dsp.exec_cmd("discord")'' { })
      (bind (modKey "P") ''hl.dsp.exec_cmd("bitwarden")'' { })
      (bind (modKey "R") ''hl.dsp.exec_cmd("rofi -show run")'' { })
      (bind (modKey "H") (cross "hl.dsp.focus" "left" "l") { })
      (bind (modKey "J") ''hl.dsp.focus({ direction = "down" })'' { })
      (bind (modKey "K") ''hl.dsp.focus({ direction = "up" })'' { })
      (bind (modKey "L") (cross "hl.dsp.focus" "right" "r") { })
      (bind (modKey "SHIFT + H") ''
        function()
          move_workspace_spatial("left")
        end
      '' { })
      (bind (modKey "SHIFT + J") ''hl.dsp.window.move({ direction = "down" })'' { })
      (bind (modKey "SHIFT + K") ''hl.dsp.window.move({ direction = "up" })'' { })
      (bind (modKey "SHIFT + L") ''
        function()
          move_workspace_spatial("right")
        end
      '' { })
      (bind (modKey "SHIFT + left") ''hl.dsp.focus({ workspace = "r-1" })'' { })
      (bind (modKey "SHIFT + right") ''hl.dsp.focus({ workspace = "r+1" })'' { })
      (bind (modKey "SHIFT + Q") ''
        function()
          focus_workspace_spatial("left")
        end
      '' { })
      (bind (modKey "SHIFT + E") ''
        function()
          focus_workspace_spatial("right")
        end
      '' { })
      (bind (modKey "SHIFT + F") "hl.dsp.window.fullscreen()" { })
      (bind (modKey "SHIFT + A") ''hl.dsp.exec_cmd("grimblast copysave area")'' { })
      (bind (modKey "SHIFT + W") ''hl.dsp.exec_cmd("grimblast copysave active")'' { })
      (bind "XF86AudioRaiseVolume" ''hl.dsp.exec_cmd("wpctl set-volume -l 1.5 @DEFAULT_SINK@ 5%+")'' {
        repeating = true;
        locked = true;
      })
      (bind "XF86AudioLowerVolume" ''hl.dsp.exec_cmd("wpctl set-volume -l 1.5 @DEFAULT_SINK@ 5%-")'' {
        repeating = true;
        locked = true;
      })
      (bind "XF86AudioMicMute" ''hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_SOURCE@ toggle")'' {
        locked = true;
      })
      (bind "XF86AudioMute" ''hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_SINK@ toggle")'' {
        locked = true;
      })
    ];
  };

  wayland.windowManager.hyprland.plugins = [ ];

  # Hyprland only picks lua vs hyprlang at compositor start. A home-manager
  # switch mid-session drops the old .conf and Hyprland writes an autogenerated
  # stub (wrong binds, gaps, rounding, border, monitors). Keep a 1:1 hyprlang
  # copy for that leftover session; the next start-hyprland uses hyprland.lua.
  xdg.configFile."hypr/hyprland.conf".text = ''
    bind = SUPER, F, exec, nautilus
    bind = SUPER, B, exec, brave
    bind = SUPER, RETURN, exec, kitty
    bind = SUPER, W, killactive
    bind = SUPER, M, exec, kitty -e btop
    bind = SUPER, O, exec, obsidian
    bind = SUPER, D, exec, discord
    bind = SUPER, P, exec, bitwarden
    bind = SUPER, R, exec, rofi -show run
    bind = SUPER, H, movefocus, l
    bind = SUPER, J, movefocus, d
    bind = SUPER, K, movefocus, u
    bind = SUPER, L, movefocus, r
    bind = SUPER SHIFT, H, movewindow, l
    bind = SUPER SHIFT, J, movewindow, d
    bind = SUPER SHIFT, K, movewindow, u
    bind = SUPER SHIFT, L, movewindow, r
    bind = SUPER SHIFT, left, workspace, r-1
    bind = SUPER SHIFT, right, workspace, r+1
    bind = SUPER SHIFT, Q, workspace, r-1
    bind = SUPER SHIFT, E, workspace, r+1
    bind = SUPER SHIFT, F, fullscreen
    bind = SUPER SHIFT, A, exec, grimblast copysave area
    bind = SUPER SHIFT, W, exec, grimblast copysave active
    bindle = ,XF86AudioRaiseVolume, exec, wpctl set-volume -l 1.5 @DEFAULT_SINK@ 5%+
    bindle = ,XF86AudioLowerVolume, exec, wpctl set-volume -l 1.5 @DEFAULT_SINK@ 5%-
    bindl = ,XF86AudioMicMute, exec, wpctl set-mute @DEFAULT_SOURCE@ toggle
    bindl = ,XF86AudioMute, exec, wpctl set-mute @DEFAULT_SINK@ toggle
    exec-once = waybar
    general {
      col.active_border = rgb(0,141,79)
      gaps_in = 2
      gaps_out = 4
    }
    gesture = 3, horizontal, workspace
    input {
      kb_layout = pl
      natural_scroll = false
    }
    monitor = HDMI-A-2,3840x2160@60,-1920x0,2
    monitor = DP-3,2560x1440@120,1440x0,1
    monitor = DP-4,2560x1440@60,0x0,1,transform,3
    monitor = Unknown-1,disabled
    decoration {
      rounding = 5
    }
    dwindle {
      split_width_multiplier = 1
      preserve_split = false
      permanent_direction_override = false
    }
  '';

  wayland.windowManager.hyprland.extraConfig = ''
    dofile("${./hypr-workspace.lua}")
  '';
}
