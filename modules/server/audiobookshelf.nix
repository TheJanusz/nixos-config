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
    port = 13378;
    openFirewall = true;
  };

  systemd.services.audiobookshelf = {
    after = [ "network.target" ];
    serviceConfig = {
      Environment = "ROUTER_BASE_PATH=/audiobookshelf";
    };
    environment = {
      NODE_EXTRA_CA_CERTS = ../../misc/rootCA.crt; 
      TRUST_PROXY = "1";
    };
  };

  age.secrets = {
    wildcard-cert = {
      file = ../../secrets/wildcard.internal.crt.age;
      owner = "caddy";
      mode = "0440";
    };
    wildcard-key = {
      file = ../../secrets/wildcard.internal.key.age;
      owner = "caddy";
      mode = "0400";
    };
  };

  services.caddy = {
    enable = true;
    virtualHosts."jellyfin.internal".extraConfig = ''
      tls ${config.age.secrets.wildcard-cert.path} ${config.age.secrets.wildcard-key.path}

      reverse_proxy http://10.100.0.1:8096 {
        header_up Host {host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-For {remote_host}
        header_up X-Real-IP {remote}
      }
    '';
    virtualHosts."nextcloud.internal".extraConfig = ''
      reverse_proxy http://10.100.0.1:7687 {
        header_up Host {host}
        header_up X-Forwarded-Proto {scheme}
      }
    '';
    virtualHosts."audiobookshelf.internal" = {
      extraConfig = ''
        tls ${config.age.secrets.wildcard-cert.path} ${config.age.secrets.wildcard-key.path}

        reverse_proxy http://10.100.0.1:${toString config.services.audiobookshelf.port} {
          header_up Host {host}
          header_up X-Forwarded-Proto {scheme}
          header_up X-Forwarded-For {remote_host}
          header_up X-Real-IP {remote}
        }
      '';
    };
    virtualHosts."authentik.internal" = {
      extraConfig = '' 
        tls ${config.age.secrets.wildcard-cert.path} ${config.age.secrets.wildcard-key.path}
        reverse_proxy http://10.100.0.1:9000 {
          header_up HOST {host}
          header_up X-Forwarded-Proto {scheme}
        }
      '';
    };
  };

  services.dnsmasq = {
    enable = true;
    settings.interface = "wg0";
    settings.expand-hosts = true;
    settings.domain = "internal";
    settings.listen-address = [ "127.0.0.1" "10.100.0.1" ];
    settings.address = [
      "/authentik.internal/10.100.0.1"
      "/audiobookshelf.internal/10.100.0.1"
      "/jellyfin.internal/10.100.0.1"
      "/nextcloud.internal/10.100.0.1"
    ];
    settings."rebind-domain-ok" = [
      "/authentik.internal/"
      "/audiobookshelf.internal/"
      "/jellyfin.internal/"
      "/nextcloud.internal/"
    ];
  };

  security.pki.certificateFiles = [ ../../misc/rootCA.crt ];
}

