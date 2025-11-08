{ config, lib, pkgs, ... }:

let  
  #config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) ["steam" "steam-unwrapped"];
in
  {
    networking.hosts = {
      "localhost:8096" = [ "jellyfin.local" ];
      "127.0.0.1:8000" = [ "audiobookshelf.local" ];
    };
}

