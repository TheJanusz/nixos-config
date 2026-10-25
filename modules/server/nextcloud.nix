{ config, pkgs, lib, ... }:
let
  port = 7687;
  # PHP-FPM's PrivateTmp and KillMode=control-group delete a go-vod it spawned
  # on every pool restart. Memories' external mode only health-checks this unit.
  goVodState = "/var/lib/nextcloud/go-vod";
  goVodBind = "127.0.0.1:47788";
  nextcloudLocalUrl = "http://127.0.0.1:${toString port}";
  ffmpeg = lib.getExe pkgs.ffmpeg-headless;
  ffprobe = lib.getExe' pkgs.ffmpeg-headless "ffprobe";
  goVodConfig = pkgs.writeText "go-vod.json" (builtins.toJSON {
    bind = goVodBind;
    ffmpeg = ffmpeg;
    ffprobe = ffprobe;
    tempdir = "${goVodState}/tmp";
    cacheDir = "${goVodState}/cache";
    nextcloudUrl = nextcloudLocalUrl;
  });
  # Same loop as upstream go-vod/entrypoint.sh: pull the binary Memories is
  # serving, and refetch when it exits 12 (-version-monitor, app upgrade).
  goVodRun = pkgs.writeShellScript "go-vod-run" ''
    set -euo pipefail
    base="${nextcloudLocalUrl}"
    config="${goVodConfig}"
    arch=$(uname -m)
    url="$base/index.php/apps/memories/static/go-vod?arch=$arch"

    while true; do
      rm -f go-vod.bin
      if ! curl -fsSL --max-time 20 -o go-vod.bin "$url"; then
        echo "go-vod: failed to fetch $url, retrying in 10s" >&2
        sleep 10
        continue
      fi
      sig=$(od -An -t x1 -N 4 go-vod.bin | tr -d ' \n')
      if [[ "$sig" != "7f454c46" ]]; then
        echo "go-vod: $url did not return an ELF binary, retrying in 10s" >&2
        sleep 10
        continue
      fi
      chmod 0755 go-vod.bin
      set +e
      ./go-vod.bin -version-monitor "$config"
      code=$?
      set -e
      if [[ "$code" -ne 12 ]]; then
        echo "go-vod: exited $code" >&2
        exit "$code"
      fi
      echo "go-vod: Memories requested a new binary, refetching" >&2
      sleep 3
    done
  '';
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
        # Executable copies of Memories' helpers. Not php-fpm's private /tmp.
        "memories.exiftool.tmp" = "${goVodState}/bin";
        "memories.vod.disable" = false;
        "memories.vod.external" = true;
        "memories.vod.bind" = goVodBind;
        "memories.vod.connect" = [ goVodBind ];
        "memories.vod.nc_url" = nextcloudLocalUrl;
        "memories.vod.ffmpeg" = ffmpeg;
        "memories.vod.ffprobe" = ffprobe;
        "memories.vod.tempdir" = "${goVodState}/tmp";
        "memories.vod.cachedir" = "${goVodState}/cache";
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

    systemd.tmpfiles.rules = [
      "d ${goVodState} 0750 nextcloud nextcloud - -"
      "d ${goVodState}/bin 0750 nextcloud nextcloud - -"
      "d ${goVodState}/run 0750 nextcloud nextcloud - -"
      "d ${goVodState}/tmp 0750 nextcloud nextcloud - -"
      "d ${goVodState}/cache 0750 nextcloud nextcloud - -"
    ];

    systemd.services.go-vod = {
      description = "Memories go-vod transcoder";
      wantedBy = [ "multi-user.target" ];
      after = [
        "nextcloud-setup.service"
        "phpfpm-nextcloud.service"
        "nginx.service"
      ];
      wants = [
        "nextcloud-setup.service"
        "phpfpm-nextcloud.service"
        "nginx.service"
      ];
      path = [
        pkgs.ffmpeg-headless
        pkgs.curl
        pkgs.coreutils
      ];
      environment = {
        LIBVA_DRIVER_NAME = "iHD";
        LIBVA_DRIVERS_PATH = "/run/opengl-driver/lib/dri";
      };
      serviceConfig = {
        Type = "simple";
        User = "nextcloud";
        Group = "nextcloud";
        SupplementaryGroups = [
          "render"
          "video"
        ];
        WorkingDirectory = "${goVodState}/run";
        ExecStart = goVodRun;
        Restart = "on-failure";
        RestartSec = 5;
        # Host /dev, plus an allow-list so the iGPU render node is usable.
        PrivateDevices = false;
        DeviceAllow = [
          "/dev/dri/renderD128 rw"
          "/dev/dri/card0 rw"
        ];
        PrivateTmp = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ goVodState ];
        NoNewPrivileges = true;
      };
      unitConfig = {
        StartLimitIntervalSec = 120;
        StartLimitBurst = 10;
      };
    };
  }

