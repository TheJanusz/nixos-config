{ config, lib, pkgs, ... }:

let  
in
{
  age.secrets.wg-privatekey = {
    file = ../../secrets/wg-privatekey.age;
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
    # address = [ "10.100.0.12/32" ];

    privateKeyFile = config.age.secrets.wg-privatekey.path;

    # dns = [ "10.100.0.1" ];

    peers = [
        {
          publicKey = "+qvhw3Mvni0mpxMQw9EbCIy7ysrpvrM0g/lAO2GXjE8=";
          allowedIPs = [ "10.100.0.1/32" ];
        }
        {
          publicKey = "ZaWx5fsejzyXHGZymPVmel8xbgrxVEL4J/5eTAvEiCs=";
          allowedIPs = [ "10.100.0.2/32" ];
        }
        {
          publicKey = "95NL8dz+xDNUgmiW6Oc9rMfFguBu9LuiUnDukkFCq2M=";
          allowedIPs = [ "10.100.0.3/32" ];
        }
        {
          publicKey = "pA2hyTfIGACpDVh23xpP8+9xVzeCJSy7aCaoYqjqnVU=";
          allowedIPs = [ "10.100.0.4/32" ];
        }
        {
          publicKey = "Q8F6OyfCIh0IP5l3OrdCEYrvlXMw2SP1gJKoks6klHE=";
          allowedIPs = [ "10.100.0.5/32" ];
        }
        # Mama telefon
        {
          publicKey = "uFcWY4IrE3/5iPJPfcRbawrWiANapbgs1es5fX8XQAE=";
          allowedIPs = [ "10.100.0.6/32" ];
        }
        # Tata telefon
        {
          publicKey = "GkTBoCmS6V6mkRzLUs9VneCwNVcs04PToEBj8x6FzEs=";
          allowedIPs = [ "10.100.0.7/32" ];
        }
        # Tata desktop
        {
          publicKey = "45lHqfHfxTlxvcyFQhAMOKmcRmxf3nJD7+IDOBWW9wA=";
          allowedIPs = [ "10.100.0.8/32" ];
        }
        # Mateusz Desktop
        {
          publicKey = "k6EkPxQlOshhxdTQMUiCR4mEYb+YShr1ueTAGWg/whA=";
          allowedIPs = [ "10.100.0.9/32" ];
        }
        # Krzysiu laptop
        {
          publicKey = "K/O4/UHpSerkJn7SPYdN2pyiZ2rfUL8M9goCjUy6PRo=";
          allowedIPs = [ "10.100.0.10/32" ];
        }
        # Globus telefon
        {
          publicKey = "7oZH2qjjG68CE/Jn+uHvR+bedJh/oAUEGX2W4uia8XY=";
          allowedIPs = [ "10.100.0.11/32" ];
        }
        #  Janusz Desktop
        {
          publicKey = "e++VPiRBioRZTfiuYEvTOiC+2TrhxRYKt8f6faMfd2M=";
          allowedIPs = [ "10.100.0.12/32" ];
        }
        # Mama laptop
        {
          publicKey = "uNagg7MXZv/IuB0T+PzcRHN6PUYkrX+In2m8irGNMRo=";
          allowedIPs = [ "10.100.0.13/32" ];
        }
        # Wiktoria telefon
        {
          publicKey = "2QxvGWoK+MukUr6l0iJ+vN/+j7CN6fZEPJE7TPbKOFo=";
          allowedIPs = [ "10.100.0.14/32" ];
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
  #         publicKey = "+qvhw3Mvni0mpxMQw9EbCIy7ysrpvrM0g/lAO2GXjE8=";
  #         allowedIPs = [ "10.100.0.1/32" ];
  #       }
  #       {
  #         publicKey = "JVFZWH+N7bpc8176K8XvaUoJ7geYafzvS2gmQE5A8y4=";
  #         allowedIPs = [ "10.100.0.2/32" ];
  #       }
  #       {
  #         publicKey = "95NL8dz+xDNUgmiW6Oc9rMfFguBu9LuiUnDukkFCq2M=";
  #         allowedIPs = [ "10.100.0.3/32" ];
  #       }
  #       {
  #         publicKey = "pA2hyTfIGACpDVh23xpP8+9xVzeCJSy7aCaoYqjqnVU=";
  #         allowedIPs = [ "10.100.0.4/32" ];
  #       }
  #       {
  #         publicKey = "Q8F6OyfCIh0IP5l3OrdCEYrvlXMw2SP1gJKoks6klHE=";
  #         allowedIPs = [ "10.100.0.5/32" ];
  #       }
  #     ];
  #     # let
  #     #   tomlData = fromTOML (builtins.readFile config.age.secrets.wg-peers.path);
  #     #   peersData = tomlData.peers or [];
  #     # in
  #     # map (peer: {
  #     #   publicKey = peer.publicKey;
  #     #   allowedIPs = peer.allowedIPs;
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

