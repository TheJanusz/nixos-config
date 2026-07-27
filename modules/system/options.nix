{ config, lib, pkgs, ... }:

# with lib;

let  
in
  {
    options = {
      multipleAllowedUnfreePredicate = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
      };
      # selfSignedCerts.domains = {
      #   type = with lib.types; listOf str;
      #   description = "List of domains to generate self-signed certificates for";
      # };
      # selfSignedCerts.certificates = {
      #   type = with lib.types; listOf attrs;
      #   description = "List of information about available certificates";
      # };
    };
  }

