# server/default.nix
{ config, lib, pkgs, ... }:
let
  inherit (lib.types) submodule;
in
  {
    options.server = lib.mkOption {
      type = submodule {
        options = {
          enable = lib.mkEnableOption "Enable server suite";
          jellyfin = lib.mkOption {
            type = submodule {
              options = {
                enable = lib.mkEnableOption "Enable Jellyfin";
              };
            };
          };
        };
      };
    };

    imports = [
      ./audiobookshelf.nix
      ./jellyfin.nix
      ./nextcloud.nix
      # ./wireguard.nix
    ];

    config = lib.mkIf config.server.enable {
      # Global server config
    };
  }   
