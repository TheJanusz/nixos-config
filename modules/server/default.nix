# server/default.nix
{ config, lib, ... }:
{
  options.server.enable = lib.mkEnableOption "Enable server suite";
  options.server.jellyfin.enable = lib.mkEnableOption "Enable Jellyfin";

  imports = [
    ./authentik.nix
    ./audiobookshelf.nix
    ./jellyfin.nix
    ./nextcloud.nix
    ./fluxer.nix
    # ./wireguard.nix
  ];

  config = lib.mkIf config.server.enable {
    # Global server config
  };
}
