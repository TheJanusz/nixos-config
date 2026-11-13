{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.server.fluxer;

  # Compose bundle from the fluxer-release tag. Images are pinned inside it.
  # FLUXER_SETTINGS_LOADED is what the bundle requires in order to run
  # Compose directly. rexctl is not involved.
  fluxerRelease = "2026.1112.20122";
  composeArchive = pkgs.fetchurl {
    url = "https://github.com/fluxerapp/fluxer/releases/download/fluxer-release%40${fluxerRelease}/fluxer-compose-${fluxerRelease}.tar.gz";
    hash = "sha256-JszInnRI6T24UOrhrYd78VhrqD/voJzHsuSMRj3S/b0=";
  };

  stateDir = "/var/lib/fluxer";

  publicEnv = pkgs.writeText "fluxer-public.env" ''
    FLUXER_SETTINGS_LOADED=true
    FLUXER_DOMAIN=${cfg.domain}
    FLUXER_PUBLIC_SCHEME=https
    FLUXER_PUBLIC_PORT=443
    FLUXER_EDGE_BIND=127.0.0.1:8080
    FLUXER_LIVEKIT_USE_EXTERNAL_IP=false
    FLUXER_LIVEKIT_NODE_IP=${cfg.livekitNodeIp}
    FLUXER_EMAIL_ENABLED=false
    FLUXER_SSO_ALLOW_PRIVATE_ADDRESSES=true
    # The bundle deletes files in the uploads bucket after 1 day unless this is off.
    FLUXER_SEAWEEDFS_UPLOADS_TTL=off
    # Bundle defaults are sized for a larger host (Postgres 5gb, API 2560mb).
    FLUXER_API_MEMORY_LIMIT=1gb
    FLUXER_API_MEMORY_RESERVATION=256mb
    FLUXER_WORKER_MEMORY_LIMIT=1gb
    FLUXER_WORKER_MEMORY_RESERVATION=256mb
    FLUXER_POSTGRES_MEMORY_LIMIT=1gb
    FLUXER_POSTGRES_MEMORY_RESERVATION=256mb
    # Bundle shm (1gb) and shared_buffers (512MB) do not fit the 1gb cap above.
    FLUXER_POSTGRES_SHM_SIZE=256mb
    FLUXER_POSTGRES_SHARED_BUFFERS=128MB
    FLUXER_POSTGRES_MAINTENANCE_WORK_MEM=64MB
    FLUXER_POSTGRES_AUTOVACUUM_WORK_MEM=64MB
    FLUXER_SEAWEEDFS_MEMORY_LIMIT=512mb
    FLUXER_SEAWEEDFS_GOMEMLIMIT=384MiB
    FLUXER_MEILISEARCH_MEMORY_LIMIT=384mb
    FLUXER_MEILISEARCH_MAX_INDEXING_MEMORY=192mb
    FLUXER_GATEWAY_MEMORY_LIMIT=512mb
    FLUXER_GATEWAY_MEMORY_RESERVATION=256mb
    FLUXER_MEDIA_PROXY_MEMORY_LIMIT=512mb
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
    ${pkgs.gzip}/bin/gzip -dc ${composeArchive} | ${pkgs.gnutar}/bin/tar -x -C ${stateDir}
  '';

  # The age file is filled by hand. Fail before the compose files are replaced
  # when the secret this release adds is still absent, or when an old LiveKit
  # URL would send clients to a path this Caddyfile does not serve.
  checkSecrets = pkgs.writeShellScript "fluxer-check-secrets" ''
    set -euo pipefail
    envf=${config.age.secrets.fluxer-env.path}
    if [ ! -r "$envf" ]; then
      echo "fluxer-env is not readable at $envf" >&2
      exit 1
    fi
    pseudonym=
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        FLUXER_PROFILE_PSEUDONYM_SECRET=)
          ;;
        FLUXER_PROFILE_PSEUDONYM_SECRET=*)
          pseudonym=1
          ;;
        FLUXER_LIVEKIT_URL=*gateway/livekit*)
          echo "Delete FLUXER_LIVEKIT_URL from secrets/fluxer-env.age. This release serves voice at /livekit." >&2
          exit 1
          ;;
      esac
    done < "$envf"
    if [ -z "$pseudonym" ]; then
      echo "Add FLUXER_PROFILE_PSEUDONYM_SECRET to secrets/fluxer-env.age (openssl rand -hex 32). See modules/server/fluxer.env.example." >&2
      exit 1
    fi
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

    natsVol=/var/lib/docker/volumes/fluxer_nats-data/_data
    if [ -d "$natsVol" ]; then
      tar czf "$backupDir/nats-$ts.tgz" -C "$natsVol" .
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
    find "$backupDir" -maxdepth 1 -type f -name 'nats-*.tgz' -mtime +14 -delete
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
        Host directory for the daily Postgres dump, plus Valkey and NATS tarballs.
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
          ExecStartPre = [
            checkSecrets
            copyStack
          ];
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
