{ config, lib, pkgs, ... }:

let  
in
{
  options = {
    multipleAllowedUnfreePredicate = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
    };
  };
}

