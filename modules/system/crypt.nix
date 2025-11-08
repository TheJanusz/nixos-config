{ config, lib, pkgs, ... }:

let  
  #config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) ["steam" "steam-unwrapped"];
in
{
# WIP: gpg still doesn't see YubiKey
  environment.systemPackages = with pkgs; [
    opensc
    libfido2
    pcsclite
  ];
  programs.gnupg = {
    agent.enable = true;
    agent.pinentryPackage = pkgs.pinentry-curses;
  };
  hardware.gpgSmartcards.enable = true;
  services.pcscd.enable = true; # Needed for Yubikey
  services.yubikey-agent.enable = true;
}

