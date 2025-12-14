{ config, pkgs, ... }:
let
in
{
  programs.zsh = {
    enable = true;
    history.size = 10000;
    shellAliases = {
      la = "ls -la";
    };
    oh-my-zsh = {
      enable = true;
      plugins = [ "git" "bundler" ];
      theme = "gentoo";
    };
  };
}

