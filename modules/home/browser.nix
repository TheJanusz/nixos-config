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
