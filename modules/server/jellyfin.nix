{ config, pkgs, ... }:
let
in
{
  services.jellyfin = {
    enable = true;
    openFirewall = true;
  };
}

