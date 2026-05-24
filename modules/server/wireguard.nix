{ config, pkgs, ... }: {

  networking.wireguard.enable = true;
  networking.wireguard.interfaces = {
    wg0 = {
      ips = [ "10.100.0.1/24" ];

      listenPort = 51820;

    };
  };
}
