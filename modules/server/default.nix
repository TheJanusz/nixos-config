# server/default.nix
{ config, lib, ... }:
{
  options.server.enable = lib.mkEnableOption "Enable server suite";

  imports = [
    ./authentik.nix
    ./audiobookshelf.nix
    ./jellyfin.nix
    ./seerr.nix
    ./nextcloud.nix
    ./fluxer.nix
    ./git-server.nix
    # ./wireguard.nix
  ];

  config = lib.mkIf config.server.enable {
    # Global server config
  };
}
