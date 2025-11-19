{ config, pkgs, ... }:
let
  #neovim = pkgs.neovim;
in
{
  #imports = [
  #];

  environment.etc."nextcloud-admin-pass".text = "Testing123";
  services.nextcloud = {
    enable = false;
    package = pkgs.nextcloud32;
    hostName = "localhost";
    config.adminpassFile = "/etc/nextcloud-admin-pass";
    config.dbtype = "sqlite";
    https = false;
    settings.trusted_domains = ["192.168.254.*" "localhost"];
    settings.overwriteprotocol = "http";
  };
}

