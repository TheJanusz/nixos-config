{ config, pkgs, ... }:
let
  port = 7687;
in
  {
    environment.etc."nextcloud-admin-pass".text = "Testing123";
    services.nextcloud = {
      enable = true;
      package = pkgs.nextcloud33;
      hostName = "localhost";
      config.adminuser = "admin";
      config.adminpassFile = "/etc/nextcloud-admin-pass";
      config.dbtype = "sqlite";
    # https = false;
    settings.trusted_domains = [ "0.0.0.0" "192.168.254.*" "127.0.0.1" "localhost" "nextcloud.local" ];
    # settings.overwriteprotocol = "http";
  };

  services.nginx.virtualHosts."${config.services.nextcloud.hostName}" = {
    listen = [{
      addr = "0.0.0.0";
      port = port;
    }];
  };
  # services.nginx.virtualHosts."nextcloud.local" = {  
  #   locations."/" = {
  #     proxyPass = "http://127.0.0.1:${toString port}";
  #     proxyWebsockets = true;
  #   };
  # };
}

