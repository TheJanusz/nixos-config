{
  config,
  lib,
  ...
}:
let
  cfg = config.ssh-on-boot;
in
{
  options.ssh-on-boot = {
    enable = lib.mkEnableOption "SSH in the initrd so LUKS (and then ZFS) can be unlocked remotely";

    port = lib.mkOption {
      type = lib.types.port;
      default = 2222;
      description = ''
        Initrd SSH listen port. Keep this off the running sshd (22) so known_hosts
        and git-over-SSH stay distinct. Clients: `ssh -p 2222 root@<public-ip>`.
      '';
    };

    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI… user@host" ];
      description = "Public keys that may unlock this machine. Initrd root login only.";
    };

    hostKey = lib.mkOption {
      type = lib.types.str;
      default = "/etc/secrets/initrd/ssh_host_ed25519_key";
      description = ''
        Path to a dedicated initrd SSH host key on the machine being built.
        Must exist at rebuild time (not the running sshd host key — that would
        put the real host key in the unencrypted initramfs). Quoted string so
        Nix does not copy the private key into the store.

        Generate once on that machine:
          sudo mkdir -p /etc/secrets/initrd
          sudo ssh-keygen -t ed25519 -N "" -f /etc/secrets/initrd/ssh_host_ed25519_key
      '';
    };

    networkModules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "e1000e"
        "igb"
        "ixgbe"
        "r8169"
        "r8125"
        "tg3"
        "virtio_net"
      ];
      description = "NIC drivers to include in the initrd. Add extras if DHCP never comes up.";
    };

    interface = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "enp7s0";
      description = ''
        Ethernet interface for initrd DHCP. null matches every ethernet NIC
        (fine for a single-uplink server; set a name if multiple ports confuse wait-online).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.authorizedKeys != [ ];
        message = "ssh-on-boot.enable requires ssh-on-boot.authorizedKeys (at least one public key).";
      }
    ];

    boot.initrd.availableKernelModules = cfg.networkModules;

    boot.initrd.network = {
      enable = true;
      ssh = {
        enable = true;
        port = cfg.port;
        hostKeys = [ cfg.hostKey ];
        # systemd initrd: drop into the password agent instead of a dead shell
        authorizedKeys = map (key: ''command="systemctl default" ${key}'') cfg.authorizedKeys;
      };
    };

    boot.initrd.systemd.network = {
      enable = true;
      wait-online.anyInterface = true;
      networks."10-ssh-on-boot" = {
        matchConfig =
          if cfg.interface != null then
            { Name = cfg.interface; }
          else
            { Type = "ether"; };
        networkConfig.DHCP = "yes";
        linkConfig.RequiredForOnline =
          if cfg.interface != null then "routable" else "no";
      };
    };

    # extraPools ZFS key prompts run in stage 2 and can block multi-user
    # (normal sshd) after initrd SSH is already gone. Start sshd at basic.target
    # so you can `systemd-tty-ask-password-agent` / `zfs load-key` over port 22.
    systemd.services.sshd.wantedBy = [ "basic.target" ];
  };
}
