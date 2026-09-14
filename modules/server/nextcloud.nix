{ config, pkgs, lib, ... }:
let
  port = 7687;
in
  {
  age.secrets = {
    # wildcard-cert = {
    #   file = ../../secrets/wildcard.internal.crt.age;
    #   owner = "caddy";
    #   mode = "0440";
    # };
    nextcloud-postgres-pass = {
      file = ../../secrets/nextcloud-postgres-pass.age;
      # owner = "caddy";
      # mode = "0400";
    };
  };
    environment.etc."nextcloud-admin-pass".text = "Testing123";
    services.nextcloud = {
      enable = true;
      package = pkgs.nextcloud33;
      hostName = "nextcloud.internal";
      configureRedis = true;
      config.adminuser = "admin";
      config.adminpassFile = "/etc/nextcloud-admin-pass";
      config.dbtype = "pgsql";
      config.dbuser = "nextcloud";
      config.dbhost = "/run/postgresql";
      config.dbname = "nextcloud";
      https = true;
      settings.trusted_domains = [ "0.0.0.0" "192.168.1.*" "127.0.0.1" "localhost" "nextcloud.internal" ];
      settings.trusted_proxies = [ "127.0.0.1" ];
      settings.overwriteprotocol = "https";
      settings."allow_local_remote_servers" = true;
      settings."user_oidc" = {
        "login_label" = "Mam Paszport Polastu";
        "auto_provision" = true;
        "soft_auto_provision" = true;
        "httpclient.allowselfsigned" = true;
      };
      settings = {
        memcache.local = "\\OC\\Memcache\\APCu";
        memcache.locking = "\\OC\\Memcache\\Redis";
        maintenance_window_start = 3; # Hour in UTC
        serverid = 0;
        "memories.exiftool" = "${lib.getExe pkgs.exiftool}";
      };
      phpOptions = {
        "openssl.cafile" = "../../misc/rootCA.crt";
        "opcache.enable" = "1";
        "opcache.enable_cli" = "1";          # Crucial for CLI warnings
        "opcache.interned_strings_buffer" = "16"; # Increase if needed
        "opcache.max_accelerated_files" = "10000";
        "opcache.memory_consumption" = "256";     # Increase if needed
        "opcache.save_comments" = "1";
        "opcache.revalidate_freq" = "1";
      };
      phpExtraExtensions = ps: [
        ps.apcu
      ];
      # datadir = "/data/nextcloud";
      # home = "/data/nextcloud";
      caching = {
        apcu = true;
        redis = true;
      };
      appstoreEnable = true;
    };
    services.redis.servers.nextcloud.enable = true;

    services.nginx.virtualHosts."${config.services.nextcloud.hostName}" = {
      listen = [{
        addr = "0.0.0.0";
        port = port;
      }];
    };

    services.postgresql = {
      enable = true;
      ensureDatabases = [ "nextcloud" ];
      ensureUsers = [
        {
          name = "nextcloud";
          ensureDBOwnership = true;
          ensureClauses = {
            login = true;
          };
        }
      ];
    };

    systemd.services."nextcloud-setup" = {
      requires = [ "postgresql.service" ];
      after = [ "postgresql.service" ];
      wants = [ "postgresql.service" ];
    };
  }

