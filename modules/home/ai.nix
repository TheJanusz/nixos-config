{ config, pkgs, ... }:

let
in
{
  home.packages = with pkgs; [
    llama-cpp
  ];
}
