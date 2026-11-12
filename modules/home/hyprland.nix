{ config, pkgs, lib, ... }:
let
  inherit (lib.generators) mkLuaInline;
  bind = keys: dsp: flags: {
    _args = [ keys (mkLuaInline dsp) ] ++ lib.optional (flags != { }) flags;
  };
  modKey = rest: mkLuaInline ''mod .. " + ${rest}"'';
  # {text} drops the combi mode name. fzf sort ranks the visible name, so
  # "Steam" beats a game whose launch command merely contains steam.
  rofi-launcher = "rofi -show combi -combi-modes drun,run -combi-display-format {text} -sort -sorting-method fzf";
  # BSD-3 Lua package. Gives each monitor a fixed workspace range.
  split-monitor-workspaces = pkgs.fetchFromGitHub {
    owner = "zjeffer";
    repo = "split-monitor-workspaces";
    rev = "d6b45cdb9b30c388bc4ded4adad78a14e523d591";
    hash = "sha256-AIg6hxip9hP6XWIqpjQOIripCdJQvtKSEubV+qL8mF8=";
  };
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
  # X11 games read the XWayland primary before their window exists. Hyprland
  # drops that flag on startup and when monitors wake, so keep DP-3 primary.
  xwayland-primary = pkgs.writeShellScriptBin "xwayland-primary-dp3" ''
    ${pkgs.python3}/bin/python3 - <<'PY'
    import os, socket, subprocess, time

    xrandr = "${pkgs.xrandr}/bin/xrandr"

    def set_primary():
        subprocess.run([xrandr, "--output", "DP-3", "--primary"], check=False)

    def dp3_connected():
        try:
            out = subprocess.check_output([xrandr, "--query"], text=True, stderr=subprocess.DEVNULL)
        except (OSError, subprocess.CalledProcessError):
            return False
        return any(line.startswith("DP-3 connected") for line in out.splitlines())

    for _ in range(60):
        if dp3_connected():
            set_primary()
            break
        time.sleep(1)

    def events():
        signature = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
        runtime = os.environ.get("XDG_RUNTIME_DIR", "")
        path = f"{runtime}/hypr/{signature}/.socket2.sock"
        while True:
            try:
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                sock.connect(path)
                buf = b""
                while True:
                    chunk = sock.recv(4096)
                    if not chunk:
                        break
                    buf += chunk
                    while b"\n" in buf:
                        line, buf = buf.split(b"\n", 1)
                        if line.startswith(b"monitoradded"):
                            set_primary()
            except OSError:
                time.sleep(2)

    import threading
    threading.Thread(target=events, daemon=True).start() while True:
        time.sleep(30)
        set_primary()
    PY
  '';
in
{
  home.packages = [
    pkgs.grimblast # screenshots
    pkgs.libnotify
    hypr-session-restore
  ];
  # The compositor start hook launches mako. The D-Bus service file asks
  # systemd for mako.service, so that unit has to exist or activation fails.
  # It is not WantedBy the session; hyprland.start is the start path.
  services.mako = {
    enable = true;
    settings = {
      anchor = "bottom-center";
      layer = "overlay";
      border-size = 2;
      border-radius = 5;
      border-color = "#008d4f";
      background-color = "#1e1e1e";
      text-color = "#ffffff";
      # 0 never expires. ignore-timeout drops the expire time apps send.
      default-timeout = 0;
      ignore-timeout = true;
      # Left click would otherwise invoke the default action and focus the sender.
      on-button-left = "dismiss";
      icons = true;
      max-visible = 5;
    };
  };
  systemd.user.services.mako = {
    Unit = {
      Description = "Lightweight Wayland notification daemon";
      Documentation = "man:mako(1)";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Service = {
      Type = "dbus";
      BusName = "org.freedesktop.Notifications";
      ExecCondition = "${pkgs.runtimeShell} -c '[ -n \"$WAYLAND_DISPLAY\" ]'";
      ExecStart = lib.getExe config.services.mako.package;
      ExecReload = "${lib.getExe' config.services.mako.package "makoctl"} reload";
    };
  };
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
      binds = {
        window_direction_monitor_fallback = true;
      };
      gestures = {
        workspace_swipe_create_new = false;
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
    on = {
      _args = [
        "hyprland.start"
        (mkLuaInline ''
          function()
            hl.exec_cmd("${lib.getExe config.programs.waybar.package}")
            hl.exec_cmd("sh -c 'sleep 2 && hypr-session-restore restore'")
            hl.exec_cmd("sh -c 'pgrep -f \"[h]ypr-session-restore daemon\" >/dev/null || hypr-session-restore daemon'")
            hl.exec_cmd("sh -c 'pgrep -f \"[x]wayland-primary-dp3\" >/dev/null || ${lib.getExe xwayland-primary}'")
            hl.exec_cmd("sh -c 'pgrep -x mako >/dev/null || ${lib.getExe config.services.mako.package}'")
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
      (bind (modKey "R") ''hl.dsp.exec_cmd("${rofi-launcher}")'' { })
      (bind (modKey "H") ''hl.dsp.focus({ direction = "left" })'' { })
      (bind (modKey "J") ''hl.dsp.focus({ direction = "down" })'' { })
      (bind (modKey "K") ''hl.dsp.focus({ direction = "up" })'' { })
      (bind (modKey "L") ''hl.dsp.focus({ direction = "right" })'' { })
      (bind (modKey "SHIFT + H") ''
        function()
          move_window("left")
        end
      '' { })
      (bind (modKey "SHIFT + J") ''hl.dsp.window.move({ direction = "down" })'' { })
      (bind (modKey "SHIFT + K") ''hl.dsp.window.move({ direction = "up" })'' { })
      (bind (modKey "SHIFT + L") ''
        function()
          move_window("right")
        end
      '' { })
      (bind (modKey "SHIFT + left") ''
        function()
          smw.workspace("-1")()
        end
      '' { })
      (bind (modKey "SHIFT + right") ''
        function()
          smw.workspace("+1")()
        end
      '' { })
      (bind (modKey "SHIFT + Q") ''
        function()
          smw.workspace("-1")()
        end
      '' { })
      (bind (modKey "SHIFT + E") ''
        function()
          smw.workspace("+1")()
        end
      '' { })
      (bind (modKey "SHIFT + F") ''hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle" })'' { })
      (bind (modKey "SHIFT + A") ''hl.dsp.exec_cmd("grimblast copysave area")'' { })
      (bind (modKey "SHIFT + W") ''hl.dsp.exec_cmd("grimblast copysave active")'' { })
      (bind (modKey "G") ''hl.dsp.exec_cmd("${lib.getExe' config.services.mako.package "makoctl"} dismiss")'' { })
      (bind (modKey "SHIFT + G") ''hl.dsp.exec_cmd("${lib.getExe' config.services.mako.package "makoctl"} restore")'' { })
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
    # float is static: it sees initial class and initial title only. Brave
    # extension popups carry the extension id there, then rename themselves.
    window_rule = [
      {
        name = "float-brave-extension-class";
        # PWAs use this same class with the app name as the initial title.
        # Extension popups use _crx_<id> until they rename themselves.
        match.class = "brave-[a-p]{32}-Default";
        match.initial_title = "_crx_[a-p]{32}";
        float = true;
      }
      {
        name = "float-brave-extension-title";
        # Installed PWAs share this initial title but use class crx_<id>.
        match.class = "negative:crx_[a-p]{32}";
        match.initial_title = "_crx_[a-p]{32}";
        float = true;
      }
      {
        name = "size-bitwarden-class";
        # FullMatch: the whole class is brave-<id>-Default, not the id alone.
        match.class = "brave-nngceckbapebfimnlniiiahkandclblb-Default";
        float = true;
        size = "400 600";
        center = true;
      }
      {
        name = "size-bitwarden-title";
        match.initial_title = "_crx_nngceckbapebfimnlniiiahkandclblb";
        float = true;
        size = "400 600";
        center = true;
      }
      {
        name = "tile-brave-pwa";
        match.class = "brave-[a-p]{32}-Default";
        match.initial_title = "negative:_crx_[a-p]{32}";
        tile = true;
      }
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
    bind = SUPER, R, exec, ${rofi-launcher}
    bind = SUPER, H, movefocus, l
    bind = SUPER, J, movefocus, d
    bind = SUPER, K, movefocus, u
    bind = SUPER, L, movefocus, r
    bind = SUPER SHIFT, H, movewindow, l
    bind = SUPER SHIFT, J, movewindow, d
    bind = SUPER SHIFT, K, movewindow, u
    bind = SUPER SHIFT, L, movewindow, r
    bind = SUPER SHIFT, left, workspace, m-1
    bind = SUPER SHIFT, right, workspace, m+1
    bind = SUPER SHIFT, Q, workspace, m-1
    bind = SUPER SHIFT, E, workspace, m+1
    bind = SUPER SHIFT, F, fullscreen, 1
    bind = SUPER SHIFT, A, exec, grimblast copysave area
    bind = SUPER SHIFT, W, exec, grimblast copysave active
    bind = SUPER, G, exec, ${lib.getExe' config.services.mako.package "makoctl"} dismiss
    bind = SUPER SHIFT, G, exec, ${lib.getExe' config.services.mako.package "makoctl"} restore
    bindle = ,XF86AudioRaiseVolume, exec, wpctl set-volume -l 1.5 @DEFAULT_SINK@ 5%+
    bindle = ,XF86AudioLowerVolume, exec, wpctl set-volume -l 1.5 @DEFAULT_SINK@ 5%-
    bindl = ,XF86AudioMicMute, exec, wpctl set-mute @DEFAULT_SOURCE@ toggle
    bindl = ,XF86AudioMute, exec, wpctl set-mute @DEFAULT_SINK@ toggle
    exec-once = waybar
    exec-once = sh -c 'pgrep -f "[x]wayland-primary-dp3" >/dev/null || ${lib.getExe xwayland-primary}'
    exec-once = sh -c 'pgrep -x mako >/dev/null || ${lib.getExe config.services.mako.package}'
    windowrule = match:class brave-[a-p]{32}-Default, match:initial_title _crx_[a-p]{32}, float on
    windowrule = match:class negative:crx_[a-p]{32}, match:initial_title _crx_[a-p]{32}, float on
    windowrule = match:class brave-nngceckbapebfimnlniiiahkandclblb-Default, float on, size 400 600, center on
    windowrule = match:initial_title _crx_nngceckbapebfimnlniiiahkandclblb, float on, size 400 600, center on
    windowrule = match:class brave-[a-p]{32}-Default, match:initial_title negative:_crx_[a-p]{32}, tile on
    general {
      col.active_border = rgb(0,141,79)
      gaps_in = 2
      gaps_out = 4
    }
    binds {
      window_direction_monitor_fallback = true
    }
    gestures {
      workspace_swipe_create_new = false
    }
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
    package.path = "${split-monitor-workspaces}/lua/?.lua;" .. package.path
    dofile("${./hypr-workspace.lua}")
  '';
}
