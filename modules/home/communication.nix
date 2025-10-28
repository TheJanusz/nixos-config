{ config, lib, pkgs, ... }:

let  
in
{
  home.packages = with pkgs; [
    discord
    telegram-desktop
  ];
}

