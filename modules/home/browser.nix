{ config, lib, options, ... }:
let
  cfg = config.browser;

  webAppPolicy = app: {
    url = app.url;
    default_launch_container = "window";
    create_desktop_shortcut = true;
  } // lib.optionalAttrs (app.name != null) {
    custom_name = app.name;
    fallback_app_name = app.name;
  };

  # Host of https://fluxer.internal/ is fluxer.internal. Used when name is unset.
  webAppHost = url:
    let
      rest = lib.removePrefix "https://" (lib.removePrefix "http://" url);
      hostPort = lib.head (lib.splitString "/" rest);
    in
    lib.head (lib.splitString ":" hostPort);

  webAppLabel = app: if app.name != null then app.name else webAppHost app.url;

  # fluxer.desktop. A null name uses the host so the file id still exists.
  webAppEntryId = app:
    lib.toLower (builtins.replaceStrings [ " " ] [ "-" ] (webAppLabel app));
in
{
  options.browser.webApps = lib.mkOption {
    type = lib.types.listOf (lib.types.submodule {
      options = {
        url = lib.mkOption {
          type = lib.types.str;
          description = "Final non-redirecting https URL of the web app.";
        };
        name = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Launcher name. Brave uses the manifest name when this is unset.";
        };
        icon = lib.mkOption {
          type = lib.types.nullOr (lib.types.either lib.types.str lib.types.path);
          default = null;
          description = "Launcher icon. A path is copied into the Nix store.";
        };
      };
    });
    default = import ./web-apps.nix;
    description = "Web apps Brave force-installs on the desktop via WebAppInstallForceList.";
  };

  # Imported by Home Manager and the desktop NixOS config. optionalAttrs drops
  # the attr entirely; mkIf would still define an option the other side lacks.
  config = lib.optionalAttrs (options ? home) {
    programs.brave = {
      enable = true;
      # package = pkgs.brave;
      # Last --enable-features wins over the nixpkgs wrapper; keep its features plus NVIDIA.
      commandLineArgs = [
        "--enable-features=AcceleratedVideoDecodeLinuxGL,AcceleratedVideoEncoder,VaapiOnNvidiaGPUs,VaapiIgnoreDriverChecks,WaylandWindowDecorations,WaylandLinuxDrmSyncobj"
        "--ignore-gpu-blocklist"
        "--use-gl=angle"
        "--use-angle=gl"
        "--enable-wayland-ime=true"
      ];
      extensions = [
        { id = "hnmpcagpplmpfojmgmnngilcnanddlhb"; } # Windscribe
        { id = "nngceckbapebfimnlniiiahkandclblb"; } # Bitwarden
        { id = "ponfpcnoihfmfllpaingbgckeeldkhle"; } # Enhancer for YouTube
        { id = "eimadpbcbfnmbkopoojfekhnkhdbieeh"; } # Dark Reader
        # { id = "ankepacjgoajhjpenegknbefpmfffdic"; } # disable-youtube-shorts
        { id = "lcdlignfoefnkcfejmlnegoobondbfjb"; } # Display youtube dislikes
        { id = "ndpmhjnlfkgfalaieeneneenijondgag"; } # YouTube Anti Translate
      ];
      #defaultSearchProviderEnabled = true;
      #defaultSearchProviderSearchURL = "https://startpage.com";
    };

    # Brave rewrites its own shortcut with NoDisplay=true. This file is ours.
    xdg.desktopEntries = lib.listToAttrs (map (app: {
      name = webAppEntryId app;
      value = {
        name = webAppLabel app;
        exec = "brave --app=${app.url}";
        terminal = false;
        categories = [ "Network" ];
      } // lib.optionalAttrs (app.icon != null) {
        icon = app.icon;
      };
    }) cfg.webApps);

    # programs.firefox = {
    #   enable = true;
    #   package = pkgs.firefox-devedition;
    #   configPath = "${config.xdg.configHome}/.config/mozilla/firefox";
    # };
  } // lib.optionalAttrs (options ? environment) {
    environment.etc."brave/policies/managed/pwas.json" = lib.mkIf (cfg.webApps != [ ]) {
      text = builtins.toJSON {
        WebAppInstallForceList = map webAppPolicy cfg.webApps;
      };
    };
  };
}
