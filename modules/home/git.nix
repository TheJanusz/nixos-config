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
      user.signingkey = "59B0B335499AA4D4";
      gpg.format = "openpgp";
      commit.gpgsign = true;
      tag.gpgSign = true;
    };
  };
}
