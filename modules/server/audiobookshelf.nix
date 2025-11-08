{ config, pkgs, ... }:
let
in
{
  #imports = [
  #];

  #home.packages = with pkgs; [ audiobookshelf ];

  services.audiobookshelf = {
    enable = true;
    package = pkgs.audiobookshelf;
    host = "0.0.0.0";
    openFirewall = true;
  };

  services.nginx = {
    enable = true;
    clientMaxBodySize = "10G";
    recommendedProxySettings = true;
      virtualHosts."localhost" = {
        #forceSSL = true; # Optional, but highly recommended
        locations."/" = {
          proxyPass = "http://127.0.0.1:${builtins.toString config.services.audiobookshelf.port}";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_redirect http:// $scheme://;
          '';
        };
        #useACMEHost = "[attribute name from security.acme.certs]"; # Optional, but highly recommended
      };
    };
}

