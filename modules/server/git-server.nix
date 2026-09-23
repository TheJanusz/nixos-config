{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.server.git-server;
  domain = "git.internal";
  bindIp = "10.100.0.1";
  stateDir = "/data/forgejo";
  backupDir = "/data/backups/forgejo";
  httpPort = 3000;
in
{
  options.server.git-server = {
    enable = lib.mkEnableOption "Forgejo git server on git.internal";
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.caddy.enable;
        message = "server.git-server requires services.caddy (already enabled by the server suite).";
      }
      {
        assertion = config.services.openssh.enable;
        message = "server.git-server uses host OpenSSH for git@git.internal clones.";
      }
    ];

    # Unix user `git` so clone URLs are git@git.internal:owner/repo.git on port 22.
    # The NixOS Forgejo module only auto-creates the account when the name is forgejo.
    users.users.git = {
      isSystemUser = true;
      group = "git";
      home = stateDir;
      useDefaultShell = true;
    };
    users.groups.git = { };

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0750 git git -"
      "d ${backupDir} 0750 git git -"
    ];

    services.openssh.settings.AllowUsers = [ "git" ];
    # SHA-256 remotes need protocol v2; sshd drops GIT_PROTOCOL unless allowed.
    # Forgejo: Match User git / AcceptEnv GIT_PROTOCOL (host OpenSSH, not built-in).
    services.openssh.settings.AcceptEnv = [ "GIT_PROTOCOL" ];
    services.openssh.extraConfig = ''
      Match User git
        AcceptEnv GIT_PROTOCOL
        SetEnv PATH=${lib.makeBinPath [ pkgs.git ]}:/run/current-system/sw/bin
    '';

    # Host SSH (forgejo serv) does not inherit forgejo.service's PATH.
    environment.systemPackages = [ pkgs.git ];
    programs.git.enable = true;

    services.forgejo = {
      enable = true;
      user = "git";
      group = "git";
      stateDir = stateDir;
      lfs.enable = true;
      database = {
        type = "postgres";
        user = "git";
        name = "git";
      };
      dump = {
        enable = true;
        backupDir = backupDir;
      };
      settings = {
        server = {
          DOMAIN = domain;
          ROOT_URL = "https://${domain}/";
          HTTP_ADDR = "127.0.0.1";
          HTTP_PORT = httpPort;
          SSH_DOMAIN = domain;
          SSH_PORT = 22;
          SSH_USER = "git";
        };
        session.COOKIE_SECURE = true;
        service.DISABLE_REGISTRATION = true;
      };
    };

    services.caddy.virtualHosts.${domain}.extraConfig = ''
      tls ${config.age.secrets.wildcard-cert.path} ${config.age.secrets.wildcard-key.path}

      request_body {
        max_size 512MB
      }

      reverse_proxy http://127.0.0.1:${toString httpPort} {
        header_up Host {host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-For {remote_host}
        header_up X-Real-IP {remote}
      }
    '';

    services.dnsmasq.settings.address = [ "/${domain}/${bindIp}" ];
    services.dnsmasq.settings."rebind-domain-ok" = [ "/${domain}/" ];
  };
}
