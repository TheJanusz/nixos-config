{ config, lib, pkgs, ... }:

let  
in
{
  age.secrets.wg-privatekey = {
    file = ../../secrets/wg-privatekey.age;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  # Enable networking
  networking.hostName = "nixos"; # Define your hostname.
  networking.networkmanager.enable = true;
  networking.nameservers = [ "9.9.9.9" ];
  networking.firewall.allowedTCPPorts = [ 80 443 ];
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # WireGuard
  networking.firewall.trustedInterfaces = [ "wg0" ];
  networking.firewall.allowedUDPPorts = [ 51820 ];
  networking.firewall.checkReversePath = "loose";
  networking.firewall.extraInputRules = [
    {
      interface = "wg0";
      protocol = "tcp";
      destinationPort = 8096;
      actuon = "accept";
    }
  ];
  networking.wireguard.interfaces.wg0 = {
    ips = [ "10.100.0.1/24" ];
    listenPort = 51820;
    privateKeyFile = config.age.secrets.wg-privatekey.path;

    peers = [
      {
        publicKey = "+qvhw3Mvni0mpxMQw9EbCIy7ysrpvrM0g/lAO2GXjE8=";
        allowedIPs = [ "10.100.0.1/32" ];
      }
      {
        publicKey = "JVFZWH+N7bpc8176K8XvaUoJ7geYafzvS2gmQE5A8y4=";
        allowedIPs = [ "10.100.0.50/32" ];
      }
    ];
  };
  networking.nat = {
    enable = true;
    externalInterface = "enp7s0";
    internalInterfaces = [ "wg0" ];
  };
}

