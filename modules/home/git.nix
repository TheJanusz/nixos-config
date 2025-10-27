{ config, pkgs, ... }:
let
  #neovim = pkgs.neovim;
in
{
  #imports = [
  #];
  #programs.gnupg.enable = true;
  programs.git = {
    enable = true;   
  };
}
