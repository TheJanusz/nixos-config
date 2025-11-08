{ config, pkgs, ... }:
let
  #neovim = pkgs.neovim;
in
{
  #imports = [
  #];
  programs.git = {
    enable = true;
    settings = {
      user.name = "TheJanusz";
      user.email = "pietrzyk.janusz1@gmail.com";
      gpg.format = "openpgp";
      commit.gpgsign = true;
      tag.gpgSign = true;
    };
  };
}
