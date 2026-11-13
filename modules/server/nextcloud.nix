{ config, pkgs, lib, ... }:
let
  port = 7687;
  collaboraPort = 9980;
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
        # System bundle already includes misc/rootCA.crt via security.pki.certificateFiles.
        # A repo-relative path is missing from php-fpm's cwd, so discovery TLS fails.
        "openssl.cafile" = config.security.pki.caBundle;
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
      extraAppsEnable = true;
      extraApps = {
        inherit (config.services.nextcloud.package.packages.apps) richdocuments;
      };
    };
    services.redis.servers.nextcloud.enable = true;

    services.nginx.virtualHosts."${config.services.nextcloud.hostName}" = {
      listen = [{
        addr = "127.0.0.1";
        port = port;
      }];
    };

    # coolwsd WOPI callbacks to https://nextcloud.internal hit local Caddy,
    # not the wg0 hairpin to 10.100.0.1.
    networking.hosts."127.0.0.1" = [ "nextcloud.internal" ];

    services.collabora-online = {
      enable = true;
      port = collaboraPort;
      aliasGroups = [{ host = "https://nextcloud.internal"; }];
      settings = {
        server_name = "nextcloud.internal";
        ssl.enable = false;
        ssl.termination = true;
        # Outbound WOPI to Nextcloud is still HTTPS; use the system bundle
        # (includes misc/rootCA.crt) instead of Collabora's dummy CA chain.
        ssl.ca_file_path = config.security.pki.caBundle;
        # proto=all binds ::1 only, which refuses 127.0.0.1. WOPI and Caddy use that address.
        net.proto = "IPv4";
        net.listen = "loopback";
        net.post_allow.host = [ ''127\.0\.0\.1'' "::1" ];
        storage.wopi."@allow" = true;
        storage.wopi.host = [ ''nextcloud\.internal'' ];
        num_prespawn_children = 1;
      };
    };

    services.caddy.virtualHosts."nextcloud.internal".extraConfig = ''
      tls ${config.age.secrets.wildcard-cert.path} ${config.age.secrets.wildcard-key.path}

      @collabora path /browser* /hosting* /cool* /lool*
      handle @collabora {
        reverse_proxy http://127.0.0.1:${toString collaboraPort} {
          header_up Host {host}
          header_up X-Forwarded-Proto {scheme}
          header_up X-Forwarded-For {remote_host}
        }
      }
      handle {
        reverse_proxy http://127.0.0.1:${toString port} {
          header_up Host {host}
          header_up X-Forwarded-Proto {scheme}
          header_up X-Forwarded-For {remote_host}
          header_up X-Real-IP {remote}
        }
      }
    '';

    systemd.services.nextcloud-config-collabora =
      let
        occ = lib.getExe config.services.nextcloud.occ;
        wopiUrl = "http://127.0.0.1:${toString collaboraPort}";
        callbackUrl = "https://${config.services.nextcloud.hostName}";
      in
      {
        description = "Configure Nextcloud Office (richdocuments) for local Collabora";
        wantedBy = [ "multi-user.target" ];
        after = [
          "nextcloud-setup.service"
          "coolwsd.service"
        ];
        requires = [ "coolwsd.service" ];
        wants = [ "nextcloud-setup.service" ];
        script = ''
          set -euo pipefail
          ${occ} config:app:set richdocuments wopi_url --value ${lib.escapeShellArg wopiUrl}
          ${occ} config:app:set richdocuments wopi_callback_url --value ${lib.escapeShellArg callbackUrl}
          ${occ} config:app:set richdocuments wopi_allowlist --value ${lib.escapeShellArg "127.0.0.1,::1"}
          ${occ} config:app:set richdocuments preview_generation --type boolean --value false
          if ${occ} richdocuments:setup -w ${lib.escapeShellArg wopiUrl} -c ${lib.escapeShellArg callbackUrl}; then
            :
          elif ${occ} richdocuments:activate-config; then
            :
          else
            echo "nextcloud-config-collabora: richdocuments:setup and richdocuments:activate-config both failed" >&2
            exit 1
          fi
        '';
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
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

