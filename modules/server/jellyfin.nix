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
}

