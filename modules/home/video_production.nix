{ config, pkgs, pkgs-stable, ... }:
let
in
{
  home.packages = with pkgs; [
    audacity
    pkgs-stable.kdePackages.kdenlive
    obs-studio
  ];
}
