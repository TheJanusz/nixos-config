{ config, lib, pkgs, ... }:

let  
in
{
  programs.gnupg = {
    agent.enable = true;
    agent.enableSSHSupport = true;
    agent.pinentryPackage = pkgs.pinentry-curses;
  };
}

