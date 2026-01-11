{ config, pkgs, ... }:
let
in
{
  #imports = [
  #];
  services.jellyfin = {
    enable = true;
    openFirewall = true;
  };
  networking.hosts = {
    "localhost:8096" = [ "jellyfin.local" ];
  };
}

