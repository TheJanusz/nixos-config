{
  config,
  lib,
  ...
}:
let
  cfg = config.server.jellyfin;
in
{
  options.server.jellyfin.enable = lib.mkEnableOption "Jellyfin media server";

  config = lib.mkIf cfg.enable {
    services.jellyfin = {
      enable = true;
      openFirewall = true;
    };
  };
}
