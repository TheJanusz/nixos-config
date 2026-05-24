{ config, lib, pkgs, ... }:

with lib;

let  
  # cfg = config.services.self-signed-certs;
  cfg = config.selfSignedCerts;
  certDir = "/var/lib/nginx/certs";
in
  {
    options = {
      multipleAllowedUnfreePredicate = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
      };
      selfSignedCerts.domains = {
        type = with lib.types; listOf str;
        description = "List of domains to generate self-signed certificates for";
      };
      selfSignedCerts.certificates = {
        type = with lib.types; listOf attrs;
        description = "List of information about available certificates";
      };
      # services = {
      #   self-signed-certs = {
      #     enable = mkEnableOption "Self-signed certificate generator.";
      #     domains = mkOption {
      #       type = types.listOf types.str;
      #       description = "List of domains to generate self-signed certificates for.";
      #       default = [ ];
      #     };
      #     certDir = mkOption {
      #       type = types.path;
      #       description = "Directory to store generated certificates and keys";
      #       default = "/var/lib/nginx/certs";
      #     };
      #     certificates = mkOption {
      #       # type = types.listOf types.attrs;
      #       # description = "List of generated certificate objects (domain, cert, key)";
      #       # readOnly = true;
      #       type = types.attrsOf (types.submodule {
      #         options = {
      #           domain = mkOption { type = types.str; };
      #           cert = mkOption { type = types.path; };
      #           key = mkOption { type = types.path; };
      #         };
      #       });
      #     };
      #   };
      # };
    };

    # config.selfSignedCerts.certificates = pkgs.runCommand "local-certs" { buildInputs = [ pkgs.openssl ]; }
    #   (concatMapStringsSep "\n" (domain:
    #   ''
    #     mkdir -p "${certDir}"
    #       if ! [ -f "${certDir}/${domain}.crt" ]; then
    #       echo "Generating certificate for ${domain}..."
    #       ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:4096 -keyout "${certDir}/${domain}.key" \
    #       -out "${certDir}/${domain}.crt" -days 365 -nodes -subj "/CN=${domain}"
    #       fi
    #     '') cfg.domains);
    # config = mkIf cfg.enable {
    # Generate certificate for each domain
    # system.activationScripts.self-signed-certs = {
    #   text = ''
    #     mkdir -p "${cfg.certDir}"
    #     ${lib.concatMapStringsSep "\n" (domain: ''
    #       if ! [ -f "${cfg.certDir}/${domain}.crt" ]; then
    #       echo "Generating certificate for ${domain}..."
    #       ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:4096 -keyout "${cfg.certDir}/${domain}.key" \
    #       -out "${cfg.certDir}/${domain}.crt" -days 365 -nodes -subj "/CN=${domain}"
    #       fi
    #     '') cfg.domains}
    #     '';
    #     deps = [ ];
    #   };
      #   services.self-signed-certs.certificates = builtins.listToAttrs (map (domain: {
      #     name = domain;
      #     value = {
      #       domain = domain;
      #       cert = "${cfg.certDir}/${domain}.crt";
      #       key = "${cfg.certDir}/${domain}.key";
      #     };
      #   }) cfg.domains );
      # };
    }

