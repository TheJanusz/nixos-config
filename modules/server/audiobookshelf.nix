{ config, pkgs, ... }:
let
in
  {
  #imports = [
  #];

  #home.packages = with pkgs; [ audiobookshelf ];
  # system.activationScripts.create-cert-dir = ''
  #   mkdir -p /var/lib/nginx/certs/
  # '';

  services.audiobookshelf = {
    enable = true;
    package = pkgs.unstable.audiobookshelf;
    host = "0.0.0.0";
    openFirewall = true;
  };

  services.caddy = {
    enable = true;
    virtualHosts."jellyfin.local".extraConfig = ''
      reverse_proxy http://localhost:8096
    '';
    virtualHosts."audiobookshelf.local".extraConfig = ''
      reverse_proxy http://localhost:${toString config.services.audiobookshelf.port}
    '';
    virtualHosts."nextcloud.local".extraConfig = ''
      reverse_proxy http://localhost:7687
    '';
  };

  # services.nginx = {
  #   enable = true;
  #   clientMaxBodySize = "10G";
  #   recommendedProxySettings = true;
  #   virtualHosts."audiobookshelf.local" = {
  #     # forceSSL = true;
  #     # sslCertificate = config.services.self-signed-certs.certificates."audiobookshelf.local".cert;
  #     # sslCertificateKey = config.services.self-signed-certs.certificates."audiobookshelf.local".key;
  #     locations."/audiobookshelf" = {
  #       proxyPass = "http://127.0.0.1:${toString config.services.audiobookshelf.port}";
  #       proxyWebsockets = true;
  #     };
  #   };
  #   virtualHosts."jellyfin.local" = {
  #     # forceSSL = true; 
  #     # sslCertificate = config.services.self-signed-certs.certificates."jellyfin.local".cert;
  #     # sslCertificateKey = config.services.self-signed-certs.certificates."jellyfin.local".key;
  #     locations."/" = {
  #       proxyPass = "http://127.0.0.1:8096/";
  #       proxyWebsockets = true;
  #       extraConfig = ''
  #         proxy_redirect http:// $scheme://;
  #         proxy_set_header X-Real-IP $remote_addr;
  #         proxy_set_header Upgrade $http_upgrade;
  #         proxy_set_header Connection "upgrade";
  #         proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  #         proxy_set_header X-Forwarded-Proto $scheme;
  #         proxy_set_header X-Forwarded-Protocol $scheme;
  #         proxy_set_header X-Forwarded-Host $http_host;
  #       '';
  #     };
  #     locations."/socket" = {
  #       proxyPass = "http://127.0.0.1/8086";
  #       extraConfig = ''
  #         proxy_redirect http:// $scheme://;
  #         proxy_http_version 1.1;
  #         proxy_set_header Upgrade $http_upgrade;
  #         proxy_set_header Connection "upgrade";
  #         proxy_set_header X-Real-IP $remote_addr;
  #         proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  #         proxy_set_header X-Forwarded-Proto $scheme;
  #         proxy_set_header X-Forwarded-Protocol $scheme;
  #         proxy_set_header X-Forwarded-Host $http_host;
  #       '';
  #     };
  #     #useACMEHost = "[attribute name from security.acme.certs]"; # Optional, but highly recommended
  #   };
  # };
  networking.hosts = {
    "127.0.0.1" = [ "jellyfin.local" "audiobookshelf.local" "nextcloud.local" ];
  };
}

