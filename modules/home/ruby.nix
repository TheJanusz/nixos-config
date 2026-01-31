{ config, lib, pkgs, ... }:

let  
in
{
  home.packages = with pkgs; [
    ruby_4_0

    # build
    gcc
    cmake
    libyaml
    libffi
    openssl
    zlib
  ];
}

