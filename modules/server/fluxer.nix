{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.server.fluxer;

  # deploy/self-hosting from fluxerapp/fluxer @ main, 2026-09-14
  fluxerRev = "c5aaf65a10395a0a7cd033007d7367b112ccfd2a";
  stackFile =
    name: hash:
    pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/fluxerapp/fluxer/${fluxerRev}/deploy/self-hosting/${name}";
      inherit hash;
    };

  composeYml = stackFile "docker-compose.yml" "sha256-WOBeVY6jWRfpqzHUroIwOk+ks0HrUrCGx8rUclUiJsM=";
  composeProxyYml = stackFile "docker-compose.proxy.yml" "sha256-RSmFjPBPF7bFBQTWEHsoTVP3AZZlf4OoULqxpnA+YmQ=";
  caddyfile = stackFile "Caddyfile" "sha256-6asaetmSERcvaM+icovuuG3U7SIGNcq1+EYbsrScsCM=";

  stateDir = "/var/lib/fluxer";

  publicEnv = pkgs.writeText "fluxer-public.env" ''
    FLUXER_DOMAIN=${cfg.domain}
    FLUXER_IMAGE_TAG=${cfg.imageTag}
    FLUXER_PUBLIC_SCHEME=https
    FLUXER_PUBLIC_PORT=443
    FLUXER_EDGE_BIND=127.0.0.1:8080
    FLUXER_LIVEKIT_USE_EXTERNAL_IP=false
    FLUXER_LIVEKIT_NODE_IP=${cfg.livekitNodeIp}
    FLUXER_EMAIL_ENABLED=false
    FLUXER_SSO_ALLOW_PRIVATE_ADDRESSES=true
    FLUXER_API_MEMORY_LIMIT=1gb
    FLUXER_API_MEMORY_RESERVATION=256mb
    FLUXER_WORKER_MEMORY_LIMIT=1gb
    FLUXER_WORKER_MEMORY_RESERVATION=256mb
    FLUXER_POSTGRES_MEMORY_LIMIT=1gb
    FLUXER_POSTGRES_MEMORY_RESERVATION=256mb
    FLUXER_SEAWEEDFS_MEMORY_LIMIT=512mb
    FLUXER_SEAWEEDFS_GOMEMLIMIT=384MiB
    FLUXER_MEILISEARCH_MEMORY_LIMIT=384mb
    FLUXER_MEILISEARCH_MAX_INDEXING_MEMORY=192mb
    FLUXER_GATEWAY_MEMORY_LIMIT=512mb
    FLUXER_GATEWAY_MEMORY_RESERVATION=256mb
  '';

  # Homelab Caddy leaves are signed by misc/rootCA.crt. The API image does not
  # inherit NixOS security.pki, so SSO token/JWKS fetch to authentik.internal
  # fails with UNABLE_TO_VERIFY_LEAF_SIGNATURE unless Node trusts this CA.
  rootCA = ../../misc/rootCA.crt;
  caCertInContainer = "/etc/ssl/certs/homelab-rootCA.crt";

  caOverlay = pkgs.writeText "docker-compose.ca.yml" ''
    services:
      api:
        volumes:
          - ${rootCA}:${caCertInContainer}:ro
        environment:
          NODE_EXTRA_CA_CERTS: ${caCertInContainer}
      worker:
        volumes:
          - ${rootCA}:${caCertInContainer}:ro
        environment:
          NODE_EXTRA_CA_CERTS: ${caCertInContainer}
  '';

  uploadsOverlay = pkgs.writeText "docker-compose.uploads.yml" ''
    services:
      seaweedfs:
        volumes: !override
          - ${cfg.uploadsDir}:/data
  '';

  extraComposeFlags =
    " -f ${caOverlay}" + lib.optionalString (cfg.uploadsDir != null) " -f ${uploadsOverlay}";

  composeBin = lib.getExe pkgs.docker-compose;

  fluxerCompose = pkgs.writeShellScript "fluxer-compose" ''
    set -euo pipefail
    exec ${composeBin} \
      --project-directory ${stateDir} \
      --project-name fluxer \
      --env-file ${publicEnv} \
      --env-file ${config.age.secrets.fluxer-env.path} \
      -f ${stateDir}/docker-compose.yml \
      -f ${stateDir}/docker-compose.proxy.yml${extraComposeFlags} \
      "$@"
  '';

  copyStack = pkgs.writeShellScript "fluxer-copy-stack" ''
    set -euo pipefail
    install -m0644 ${composeYml} ${stateDir}/docker-compose.yml
    install -m0644 ${composeProxyYml} ${stateDir}/docker-compose.proxy.yml
    install -m0644 ${caddyfile} ${stateDir}/Caddyfile
  '';

  backupScript = pkgs.writeShellScript "fluxer-backup" ''
    set -euo pipefail
    backupDir=${lib.escapeShellArg cfg.backupDir}
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    mkdir -p "$backupDir/postgres"

    ${fluxerCompose} exec -T postgres \
      pg_dump -U fluxer -d fluxer --format=custom \
      > "$backupDir/postgres/fluxer-$ts.dump"

    valkeyVol=/var/lib/docker/volumes/fluxer_valkey-data/_data
    if [ -d "$valkeyVol" ]; then
      tar czf "$backupDir/valkey-$ts.tgz" -C "$valkeyVol" .
    fi

    ${lib.optionalString (cfg.uploadsDir == null) ''
      seaweedVol=/var/lib/docker/volumes/fluxer_seaweedfs-data/_data
      if [ -d "$seaweedVol" ]; then
        mkdir -p "$backupDir/seaweedfs"
        rsync -a "$seaweedVol/" "$backupDir/seaweedfs/"
      fi
    ''}

    find "$backupDir/postgres" -type f -name 'fluxer-*.dump' -mtime +14 -delete
    find "$backupDir" -maxdepth 1 -type f -name 'valkey-*.tgz' -mtime +14 -delete
  '';
in
{
  options.server.fluxer = {
    enable = lib.mkEnableOption "Fluxer self-hosted chat (Docker Compose)";

    domain = lib.mkOption {
      type = lib.types.str;
      default = "fluxer.internal";
      description = "Public hostname browsers use. Must match DNS and the wildcard cert.";
    };

    imageTag = lib.mkOption {
      type = lib.types.str;
      default = "v1";
      description = "Fluxer image tag (FLUXER_IMAGE_TAG).";
    };

    livekitNodeIp = lib.mkOption {
      type = lib.types.str;
      default = "10.100.0.1";
      description = "Address LiveKit advertises in ICE candidates. WireGuard server IP for this homelab.";
    };

    uploadsDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/data/fluxer/uploads";
      description = ''
        Host directory for SeaweedFS (images, video, avatars, other files).
        null keeps uploads in the default Docker volume on the system disk.
        Use a string path (quoted) so Nix does not copy it into the store.
      '';
    };

    backupDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/data/fluxer/backups";
      description = ''
        Host directory for the daily Postgres dump (and Valkey AOF).
        If uploadsDir is unset, also rsyncs SeaweedFS here.
        If uploadsDir already points at ZFS, media is left to snapshots of that dataset.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = config.services.caddy.enable;
          message = "server.fluxer requires services.caddy (already enabled by the server suite).";
        }
      ];

      age.secrets.fluxer-env.file = ../../secrets/fluxer-env.age;

      virtualisation.docker.enable = true;

      systemd.tmpfiles.rules = [
        "d ${stateDir} 0750 root root -"
      ];

      systemd.services.fluxer = {
        description = "Fluxer Compose stack";
        after = [
          "docker.service"
          "network-online.target"
        ];
        requires = [ "docker.service" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        path = [
          pkgs.docker
          pkgs.docker-compose
          pkgs.coreutils
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          StateDirectory = "fluxer";
          ExecStartPre = copyStack;
          ExecStart = "${fluxerCompose} up -d --remove-orphans";
          ExecStop = "${fluxerCompose} down";
          TimeoutStartSec = "15min";
        };
      };

      services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
        tls ${config.age.secrets.wildcard-cert.path} ${config.age.secrets.wildcard-key.path}

        reverse_proxy http://127.0.0.1:8080 {
          header_up Host {host}
          header_up X-Forwarded-Proto {scheme}
          header_up X-Forwarded-For {remote_host}
          header_up X-Real-IP {remote}
        }
      '';

      services.dnsmasq.settings.address = [ "/${cfg.domain}/${cfg.livekitNodeIp}" ];
      services.dnsmasq.settings."rebind-domain-ok" = [ "/${cfg.domain}/" ];

      networking.firewall.allowedTCPPorts = [ 7881 ];
      networking.firewall.allowedUDPPorts = [ 7882 ];
    }

    (lib.mkIf (cfg.uploadsDir != null) {
      systemd.tmpfiles.rules = [
        "d ${cfg.uploadsDir} 0750 root root -"
      ];
    })

    (lib.mkIf (cfg.backupDir != null) {
      systemd.tmpfiles.rules = [
        "d ${cfg.backupDir} 0750 root root -"
        "d ${cfg.backupDir}/postgres 0750 root root -"
      ];

      systemd.services.fluxer-backup = {
        description = "Fluxer Postgres (and related) backup";
        after = [ "fluxer.service" ];
        requires = [ "fluxer.service" ];
        path = [
          pkgs.docker
          pkgs.docker-compose
          pkgs.coreutils
          pkgs.gnutar
          pkgs.gzip
          pkgs.rsync
          pkgs.findutils
        ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = backupScript;
        };
      };

      systemd.timers.fluxer-backup = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "daily";
          Persistent = true;
          RandomizedDelaySec = "30m";
        };
      };
    })
  ]);
}
