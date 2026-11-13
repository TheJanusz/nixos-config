{ config, lib, pkgs, ... }:

let  
in
{
  age.secrets.wg-privatekey = {
    file = ../../secrets/wg-privatekey.age;
    owner = "systemd-network";
    group = "systemd-network";
    mode = "640";
  };
  age.secrets.wg-client-privatekey.file = ../../secrets/wg-client-privatekey.age;
  # Peer stanzas, including the device comments, live in this file.
  # networkd reads them from /run after agenix decrypts. Nix never opens it.
  age.secrets.wg-peers = {
    file = ../../secrets/wg-peers.conf.age;
    owner = "systemd-network";
    group = "systemd-network";
    mode = "0440";
  };

  # Enable networking
  networking.hostName = "nixos"; # Define your hostname.
  networking.networkmanager.enable = true;
  networking.useNetworkd = true;
  networking.nameservers = [ "127.0.0.1" "192.168.1.1" "9.9.9.9" ];
  networking.firewall.allowedTCPPorts = [ 80 443 ];
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.
  security.pki.certificateFiles = [ ../../misc/rootCA.crt ];

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # WireGuard
  networking.firewall.trustedInterfaces = [ "wg0" ];
  networking.firewall.allowedUDPPorts = [ 51820 ];
  networking.firewall.checkReversePath = "loose";
  # systemd.network.wait-online.ignoredInterfaces = [ "wg0" ];

  systemd.services.systemd-networkd-wait-online.enable = lib.mkForce false;
  systemd.network.netdevs."50-wg0" = {
    # address = [ "10.100.0.12/32" ];

    # privateKeyFile = config.age.secrets.wg-privatekey.path;

    # dns = [ "10.100.0.1" ];
    netdevConfig = {
      Kind = "wireguard";
      Name = "wg0";
    };

    wireguardConfig = {
      PrivateKeyFile = config.age.secrets.wg-privatekey.path;
      ListenPort = 51820;
    };
  };

  # With sysusers disabled, agenix decrypts during activation, before systemd
  # starts. With sysusers enabled, agenix-chown.service must finish first
  # because networkd runs as systemd-network and the file is mode 0440.
  systemd.services.systemd-networkd = {
    after = lib.optional config.systemd.sysusers.enable "agenix-chown.service";
    wants = lib.optional config.systemd.sysusers.enable "agenix-chown.service";
    restartTriggers = [ config.age.secrets.wg-peers.file ];
    serviceConfig.ExecStartPre = lib.mkBefore [
      "+${pkgs.writeShellScript "wg-peer-dropin" ''
        set -euo pipefail
        ${pkgs.coreutils}/bin/install -d -m 0750 -o root -g systemd-network /run/systemd/network/50-wg0.netdev.d
        ${pkgs.coreutils}/bin/ln -sfn ${config.age.secrets.wg-peers.path} /run/systemd/network/50-wg0.netdev.d/peers.conf
      ''}"
    ];
  };
  systemd.network.networks."50-wg0" = {
    matchConfig.Name = "wg0";
    address = [ "10.100.0.1/24" ];
    # Only this zone goes to dnsmasq. Public names stay on the global resolvers.
    dns = [ "127.0.0.1" ];
    domains = [ "~internal" ];
  };

  # networking.nat = {
  #   enable = true;
  #   externalInterface = "enp7s0";
  #   internalInterfaces = [ "wg0" ];
  # };
}

