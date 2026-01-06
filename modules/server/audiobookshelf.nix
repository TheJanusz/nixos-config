{ config, pkgs, ... }:
let
in
{
  #imports = [
  #];

  #home.packages = with pkgs; [ audiobookshelf ];

  services.audiobookshelf = {
    enable = true;
    package = pkgs.unstable.audiobookshelf;
    host = "0.0.0.0";
    openFirewall = true;
  };

  services.nginx = {
    enable = true;
    clientMaxBodySize = "10G";
    recommendedProxySettings = true;
      virtualHosts."localhost" = {
        #forceSSL = true; # Optional, but highly recommended
        locations."/audiobookshelf" = {
          proxyPass = "http://127.0.0.1:${toString config.services.audiobookshelf.port}";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_redirect http:// $scheme://;
          '';
        };
        locations."/" = {
          proxyPass = "http://127.0.0.1:8096/";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_redirect http:// $scheme://;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header X-Forwarded-Protocol $scheme;
            proxy_set_header X-Forwarded-Host $http_host;
          '';
        };
        locations."/socket" = {
          proxyPass = "http://127.0.0.1/8086";
          extraConfig = ''
            proxy_redirect http:// $scheme://;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header X-Forwarded-Protocol $scheme;
            proxy_set_header X-Forwarded-Host $http_host;
          '';
        };
        #useACMEHost = "[attribute name from security.acme.certs]"; # Optional, but highly recommended
      };
    };
}

