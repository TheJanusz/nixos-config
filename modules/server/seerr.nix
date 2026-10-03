{
  config,
  lib,
  ...
}:
let
  cfg = config.server.seerr;
in
{
  options.server.seerr.enable = lib.mkEnableOption "Local Seerr for Jellyfin Enhanced";

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.server.jellyfin.enable;
        message = "server.seerr.enable requires server.jellyfin.enable";
      }
    ];

    services.seerr = {
      enable = true;
      openFirewall = false;
    };

    # Loopback only. wg0 is a trusted interface, so an unbound port would be
    # reachable by every WireGuard peer before the setup wizard has an admin.
    systemd.services.seerr.environment.HOST = "127.0.0.1";
  };
}
