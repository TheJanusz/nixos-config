{ config, lib, pkgs, ... }:

let  
in
{
  age.secrets.wg-client-privatekey = {
    file = ../../secrets/wg-client-privatekey.age;
    # owner = "systemd-network";
    # group = "systemd-network";
    # mode = "640";
  };
  # age.secrets.wg-peers.file = ../../secrets/wg-peers.conf.age;

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
  networking.wg-quick.interfaces.wg0 = {
    address = [ "10.100.0.12/32" ];

    privateKeyFile = config.age.secrets.wg-client-privatekey.path;

    dns = [ "10.100.0.1" ];

    peers = [
      {
        publicKey = "+qvhw3Mvni0mpxMQw9EbCIy7ysrpvrM0g/lAO2GXjE8=";

        allowedIPs = [ "10.100.0.1/32" ];

        endpoint = "95.215.29.152:51820";
      }
    ];
  };
  #   {
  #     interface = "wg0";
  #     protocol = "tcp";
  #     destinationPort = 8096;
  #     action = "accept";
  #   }
  # ];
  #
  # systemd.network = {
  #   enable = true;
  #
  #   netdevs."50-wg0" = {
  #     netdevConfig = {
  #       Kind = "wireguard";
  #       Name = "wg0";
  #     };
  #
  #     wireguardConfig = {
  #       ListenPort = 51820;
  #       PrivateKeyFile = config.age.secrets.wg-privatekey.path;
  #       FirewallMark = 42; # Marks packets for policy routing
  #     };
  #
  #     wireguardPeers = [
  #       {
  #         PublicKey = "+qvhw3Mvni0mpxMQw9EbCIy7ysrpvrM0g/lAO2GXjE8=";
  #         AllowedIPs = [ "10.100.0.1/32" ];
  #       }
  #       {
  #         PublicKey = "JVFZWH+N7bpc8176K8XvaUoJ7geYafzvS2gmQE5A8y4=";
  #         AllowedIPs = [ "10.100.0.2/32" ];
  #       }
  #       {
  #         PublicKey = "95NL8dz+xDNUgmiW6Oc9rMfFguBu9LuiUnDukkFCq2M=";
  #         AllowedIPs = [ "10.100.0.3/32" ];
  #       }
  #       {
  #         PublicKey = "pA2hyTfIGACpDVh23xpP8+9xVzeCJSy7aCaoYqjqnVU=";
  #         AllowedIPs = [ "10.100.0.4/32" ];
  #       }
  #       {
  #         PublicKey = "Q8F6OyfCIh0IP5l3OrdCEYrvlXMw2SP1gJKoks6klHE=";
  #         AllowedIPs = [ "10.100.0.5/32" ];
  #       }
  #     ];
  #     # let
  #     #   tomlData = fromTOML (builtins.readFile config.age.secrets.wg-peers.path);
  #     #   peersData = tomlData.peers or [];
  #     # in
  #     # map (peer: {
  #     #   PublicKey = peer.publicKey;
  #     #   AllowedIPs = peer.allowedIPs;
  #     # }) peersData;
  #
  #   };
  #
  #   networks."50-wg0" = {
  #     matchConfig.Name = "wg0";
  #     address = [ "10.100.0.1/24" ];
  #   };
  # };

  # networking.nat = {
  #   enable = true;
  #   externalInterface = "enp7s0";
  #   internalInterfaces = [ "wg0" ];
  # };
}

