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

    wireguardPeers = [
        {
          PublicKey = "+qvhw3Mvni0mpxMQw9EbCIy7ysrpvrM0g/lAO2GXjE8=";
          AllowedIPs = [ "10.100.0.1/32" ];
        }
        {
          PublicKey = "ZaWx5fsejzyXHGZymPVmel8xbgrxVEL4J/5eTAvEiCs=";
          AllowedIPs = [ "10.100.0.2/32" ];
        }
        {
          PublicKey = "95NL8dz+xDNUgmiW6Oc9rMfFguBu9LuiUnDukkFCq2M=";
          AllowedIPs = [ "10.100.0.3/32" ];
        }
        {
          PublicKey = "pA2hyTfIGACpDVh23xpP8+9xVzeCJSy7aCaoYqjqnVU=";
          AllowedIPs = [ "10.100.0.4/32" ];
        }
        {
          PublicKey = "Q8F6OyfCIh0IP5l3OrdCEYrvlXMw2SP1gJKoks6klHE=";
          AllowedIPs = [ "10.100.0.5/32" ];
        }
        # Mama telefon
        {
          PublicKey = "uFcWY4IrE3/5iPJPfcRbawrWiANapbgs1es5fX8XQAE=";
          AllowedIPs = [ "10.100.0.6/32" ];
        }
        # Tata telefon
        {
          PublicKey = "GkTBoCmS6V6mkRzLUs9VneCwNVcs04PToEBj8x6FzEs=";
          AllowedIPs = [ "10.100.0.7/32" ];
        }
        # Tata desktop
        {
          PublicKey = "45lHqfHfxTlxvcyFQhAMOKmcRmxf3nJD7+IDOBWW9wA=";
          AllowedIPs = [ "10.100.0.8/32" ];
        }
        # Mateusz Desktop
        {
          PublicKey = "k6EkPxQlOshhxdTQMUiCR4mEYb+YShr1ueTAGWg/whA=";
          AllowedIPs = [ "10.100.0.9/32" ];
        }
        # Krzysiu laptop
        {
          PublicKey = "K/O4/UHpSerkJn7SPYdN2pyiZ2rfUL8M9goCjUy6PRo=";
          AllowedIPs = [ "10.100.0.10/32" ];
        }
        # Globus telefon
        {
          PublicKey = "7oZH2qjjG68CE/Jn+uHvR+bedJh/oAUEGX2W4uia8XY=";
          AllowedIPs = [ "10.100.0.11/32" ];
        }
        #  Janusz Desktop
        {
          PublicKey = "e++VPiRBioRZTfiuYEvTOiC+2TrhxRYKt8f6faMfd2M=";
          AllowedIPs = [ "10.100.0.12/32" ];
        }
        # Mama laptop
        {
          PublicKey = "uNagg7MXZv/IuB0T+PzcRHN6PUYkrX+In2m8irGNMRo=";
          AllowedIPs = [ "10.100.0.13/32" ];
        }
        # Wiktoria telefon
        {
          PublicKey = "2QxvGWoK+MukUr6l0iJ+vN/+j7CN6fZEPJE7TPbKOFo=";
          AllowedIPs = [ "10.100.0.14/32" ];
        }
        # Tusia telefon
        {
          PublicKey = "tOfINUwFUgidWK8L6dEqV2YNzmb2Pz5WDLZ89KUUen8=";
          AllowedIPs = [ "10.100.0.15/32" ];
        }
        # Globus desktop
        {
          PublicKey = "Y8rv+XPv5gQDf5QrzS59zW3srKU8EpufbXF1RORYQjI=";
          AllowedIPs = [ "10.100.0.16/32" ];
        }
      ];

  };
  systemd.network.networks."50-wg0" = {
    matchConfig.Name = "wg0";
    address = [ "10.100.0.1/24" ];
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
  
  # };

  # networking.nat = {
  #   enable = true;
  #   externalInterface = "enp7s0";
  #   internalInterfaces = [ "wg0" ];
  # };
}

