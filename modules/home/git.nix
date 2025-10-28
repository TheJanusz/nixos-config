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
    settings = {
      user.name = "TheJanusz";
      user.email = "pietrzyk.janusz1@gmail.com";
    };
  };
}
