{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.server.musicbrainz;

  # metabrainz/musicbrainz-docker master, 2026-10-28.
  # Server v-2026-09-21.0, DB schema 31, Postgres 18, Solr 4.1.0, SIR 5.0.0-rc.3.
  rev = "7536deb1d528508d5ec3ee2f710f9c98c764fb01";
  src = pkgs.fetchFromGitHub {
    owner = "metabrainz";
    repo = "musicbrainz-docker";
    inherit rev;
    hash = "sha256-lLK4daqWeOACaEb2l1KIWr0INILrprPcZHFLGbKruXg=";
  };

  # Root NVMe (LUKS ext4), not the data ZFS pool.
  stateDir = "/var/lib/musicbrainz";

  tokenSource = ../../secrets/musicbrainz-replication.age;
  hasToken = builtins.pathExists tokenSource;

  composeBin = lib.getExe pkgs.docker-compose;

  # Named volumes in upstream compose would land in /var/lib/docker.
  # Bind them here so the database and indexes stay in one directory.
  # Indexer stays idle until musicbrainz-load finishes the artist/release
  # reindex; sir live then watches only those two cores.
  overlay = pkgs.writeText "musicbrainz-local.yml" ''
    services:
      db:
        volumes: !override
          - ${stateDir}/pgdata:/var/lib/postgresql
      musicbrainz:
        volumes: !override
          - ${stateDir}/dbdump:/media/dbdump
          - ${stateDir}/solrdump:/var/cache/musicbrainz/solr-backups:ro
          ${lib.optionalString hasToken "- ${src}/default/replication.cron:/crons.conf"}
      search:
        volumes: !override
          - ${stateDir}/dbdump:/media/dbdump:ro
          - ${stateDir}/solr:/var/solr
          - ${stateDir}/solrdump:/var/cache/musicbrainz/solr-backups
      indexer:
        # Clear any image entrypoint so `compose run indexer python ...` stays python.
        entrypoint: []
        volumes:
          - ${stateDir}/state:/state
        command:
          - /bin/sh
          - -c
          - |
            set -eu
            while [ ! -f /state/search-ready ]; do
              sleep 30
            done
            exec python -m sir live --entity-type artist --entity-type release
  '';

  mbCompose = pkgs.writeShellScript "musicbrainz-compose" ''
    set -euo pipefail
    export MUSICBRAINZ_SERVER_PROCESSES=${toString cfg.serverProcesses}
    ${lib.optionalString hasToken "export METABRAINZ_ACCESS_TOKEN_PATH=${config.age.secrets.musicbrainz-replication.path}"}
    exec ${composeBin} \
      --project-directory ${src} \
      --project-name musicbrainz \
      -f ${src}/docker-compose.yml \
      ${lib.optionalString hasToken "-f ${src}/compose/replication-token.yml"} \
      -f ${overlay} \
      "$@"
  '';

  loadScript = pkgs.writeShellScriptBin "musicbrainz-load" ''
    set -euo pipefail
    state=${stateDir}/state/search-ready
    if [ -f "$state" ]; then
      echo "Search index is already marked ready ($state)." >&2
      echo "Refusing to download the dumps again. Remove that file first if you mean to reload." >&2
      exit 1
    fi

    echo "Starting Postgres and Valkey..."
    ${mbCompose} up -d db valkey

    echo "Downloading the MusicBrainz dumps and loading Postgres. This takes a long time and about 100 GB."
    ${mbCompose} stop musicbrainz indexer || true
    # --no-deps keeps Solr from taking its heap while Postgres is loading.
    ${mbCompose} run --rm --no-deps musicbrainz createdb.sh -fetch

    echo "Building the artist and release search indexes (not the recording index)..."
    ${mbCompose} up -d search
    ${mbCompose} run --rm --no-deps indexer python -m sir setup
    ${mbCompose} run --rm --no-deps indexer python -m sir reindex --entity-type artist --entity-type release

    mkdir -p ${stateDir}/state
    touch "$state"
    ${mbCompose} up -d --remove-orphans

    cat <<'EOF'

    MusicBrainz is serving /ws/2/ on port 5000.
    Dump archives can be deleted from /var/lib/musicbrainz/dbdump once a lookup works.

    Point Jellyfin's MusicBrainz plugin at this mirror and set the rate limit to 0.1
    (the 1 second floor applies only to musicbrainz.org):

      homelab:  http://127.0.0.1:5000
      desktop:  http://10.100.0.1:5000   (WireGuard; the firewall does not open 5000 on the WAN)

    Cover art still comes from coverartarchive.org.
    EOF
  '';
in
{
  options.server.musicbrainz = {
    enable = lib.mkEnableOption "Private MusicBrainz mirror for Jellyfin (Docker Compose)";

    serverProcesses = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = ''
        Plack workers for the MusicBrainz web service.
        Upstream defaults to 10; 2 is enough for Jellyfin on this homelab.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    age.secrets = lib.mkIf hasToken {
      musicbrainz-replication.file = tokenSource;
    };

    virtualisation.docker.enable = true;

    environment.systemPackages = [ loadScript ];

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0755 root root -"
      "d ${stateDir}/pgdata 0755 root root -"
      "d ${stateDir}/solr 0755 root root -"
      "d ${stateDir}/dbdump 0755 root root -"
      "d ${stateDir}/solrdump 0755 root root -"
      "d ${stateDir}/state 0755 root root -"
    ];

    # Port 5000 is published on all interfaces by upstream compose and is
    # reachable on wg0 because that interface is trusted. Do not add 5000 to
    # networking.firewall.allowedTCPPorts; that would open it toward the WAN.
    systemd.services.musicbrainz = {
      description = "MusicBrainz mirror (Docker Compose)";
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
        ExecStart = "${mbCompose} up -d --remove-orphans";
        ExecStop = "${mbCompose} down";
        TimeoutStartSec = "60min";
      };
    };
  };
}
