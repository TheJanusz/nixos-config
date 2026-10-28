{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.server.lrclib;

  # tranxuanthang/lrclib main, 2026-10-28.
  rev = "e1d863afc430392c8b2f97bea72139292d498432";
  src = pkgs.fetchFromGitHub {
    owner = "tranxuanthang";
    repo = "lrclib";
    inherit rev;
    hash = "sha256-Z+fWHBr1upt6zd3aIlFVyFtB6clfnzKDp8ohd4asnTo=";
  };

  # Root NVMe (LUKS ext4), not the data ZFS pool.
  stateDir = "/var/lib/lrclib";
  database = "${stateDir}/db.sqlite3";

  # pkgs.docker's wrapper puts buildx on DOCKER_CLI_PLUGIN_DIRS. The raw
  # docker-compose binary does not, so Compose falls back to the classic
  # builder and rejects the Dockerfile's RUN --mount lines.
  dockerBin = lib.getExe pkgs.docker;

  composeFile = pkgs.writeText "lrclib-compose.yml" ''
    services:
      lrclib:
        build:
          context: ${src}
          dockerfile: Dockerfile
        image: lrclib-oss:${builtins.substring 0 12 rev}
        restart: unless-stopped
        ports:
          - "${toString cfg.port}:3300"
        environment:
          LRCLIB_LOG: info
          LRCLIB_MMAP_SIZE: "${toString cfg.mmapSize}"
          LRCLIB_CACHE_SIZE: "-${toString cfg.cacheSizeKb}"
        volumes:
          - ${stateDir}:/data
  '';

  lrclibCompose = pkgs.writeShellScript "lrclib-compose" ''
    set -euo pipefail
    export DOCKER_BUILDKIT=1
    exec ${dockerBin} compose \
      --project-directory ${stateDir} \
      --project-name lrclib \
      -f ${composeFile} \
      "$@"
  '';

  loadScript = pkgs.writeShellScriptBin "lrclib-load" ''
    set -euo pipefail
    force=0
    if [ "''${1:-}" = "--force" ]; then
      force=1
      shift
    fi
    url=''${1:-}
    if [ -z "$url" ]; then
      echo "usage: lrclib-load [--force] URL" >&2
      echo "Download a snapshot from https://lrclib.net/db-dumps" >&2
      exit 64
    fi

    db=${database}
    if [ -e "$db" ] && [ "$force" -ne 1 ]; then
      echo "Database already exists at $db." >&2
      echo "Pass --force to replace it with a newer dump." >&2
      exit 1
    fi

    mkdir -p ${stateDir}/incoming
    archive=${stateDir}/incoming/download
    sqlite_tmp=${stateDir}/incoming/db.sqlite3.partial
    rm -f "$archive.partial" "$sqlite_tmp"

    echo "Downloading $url"
    ${lib.getExe pkgs.curl} -fL --retry 5 --retry-all-errors --retry-delay 5 \
      -o "$archive.partial" "$url"
    mv -f "$archive.partial" "$archive"

    magic=$(${lib.getExe' pkgs.coreutils "od"} -An -tx1 -N4 "$archive" | tr -d ' \n')
    case "$magic" in
      28b52ffd)
        echo "Decompressing zstd dump"
        ${lib.getExe pkgs.zstd} -dc "$archive" > "$sqlite_tmp"
        ;;
      1f8b*)
        echo "Decompressing gzip dump"
        ${lib.getExe pkgs.gzip} -dc "$archive" > "$sqlite_tmp"
        ;;
      53514c69)
        mv -f "$archive" "$sqlite_tmp"
        ;;
      *)
        echo "Unrecognized dump (magic $magic). Expected zstd, gzip, or SQLite." >&2
        exit 1
        ;;
    esac

    if [ "$magic" != "53514c69" ]; then
      got=$(${lib.getExe' pkgs.coreutils "od"} -An -tx1 -N4 "$sqlite_tmp" | tr -d ' \n')
      if [ "$got" != "53514c69" ]; then
        echo "Decompressed file is not a SQLite database (magic $got)." >&2
        rm -f "$sqlite_tmp"
        exit 1
      fi
      rm -f "$archive"
    fi

    if [ "$force" -eq 1 ]; then
      systemctl stop lrclib.service || true
    fi
    mv -f "$sqlite_tmp" "$db"
    printf '%s\n' "$url" > ${stateDir}/dump-url

    echo "Starting LRCLIB. The first start builds the image and can take a while."
    systemctl start lrclib.service
    echo "LRCLIB is serving on port ${toString cfg.port}."
    echo "Jellyfin's official LrcLib plugin cannot use this host."
    echo "In the Lyrics plugin, set the LRCLIB server URL to:"
    echo "  homelab:  http://127.0.0.1:${toString cfg.port}"
    echo "  desktop:  http://10.100.0.1:${toString cfg.port}"
  '';
in
{
  options.server.lrclib = {
    enable = lib.mkEnableOption "Private LRCLIB lyrics server (Docker Compose)";

    port = lib.mkOption {
      type = lib.types.port;
      default = 3300;
      description = ''
        Host port for the LRCLIB API. Published on all interfaces.
        Do not also add it to networking.firewall.allowedTCPPorts;
        wg0 is already a trusted interface, so the desktop can reach it
        over WireGuard without opening the port toward the WAN.
      '';
    };

    mmapSize = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2 * 1024 * 1024 * 1024;
      description = ''
        SQLite mmap_size in bytes (LRCLIB_MMAP_SIZE).
        Upstream defaults to 30 GB, which should stay under about 75% of RAM.
        2 GB leaves room for the MusicBrainz database and search heaps.
      '';
    };

    cacheSizeKb = lib.mkOption {
      type = lib.types.ints.positive;
      default = 256 * 1024;
      description = ''
        SQLite page cache in kilobytes. Passed as a negative LRCLIB_CACHE_SIZE.
        Upstream defaults to about 1 GB.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.docker.enable = true;

    environment.systemPackages = [ loadScript ];

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0755 root root -"
      "d ${stateDir}/incoming 0755 root root -"
    ];

    # Port 3300 is published on all interfaces and is reachable on wg0 because
    # that interface is trusted. Do not add it to
    # networking.firewall.allowedTCPPorts; that would open it toward the WAN.
    systemd.services.lrclib = {
      description = "LRCLIB lyrics server (Docker Compose)";
      after = [
        "docker.service"
        "network-online.target"
      ];
      requires = [ "docker.service" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = database;
      path = [
        pkgs.docker
        pkgs.docker-compose
        pkgs.coreutils
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${lrclibCompose} up -d --remove-orphans --build";
        ExecStop = "${lrclibCompose} down";
        TimeoutStartSec = "120min";
      };
    };
  };
}
