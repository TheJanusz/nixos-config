{ config, pkgs, ... }:
let
  #neovim = pkgs.neovim;
in
{
  #imports = [
  #];
  home.packages = with pkgs; [
    audacity
    kdePackages.kdenlive
    obs-studio
  ];
}
