{ config, pkgs, ... }:
let
in
{
  home.packages = with pkgs; [
    audacity
    kdePackages.kdenlive
    obs-studio
  ];
}
