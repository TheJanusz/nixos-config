# Runs on boot and on each nixos-rebuild switch (the oneshot is left inactive,
# so the next switch starts it again). Fails if this host does not resolve a
# dnsmasq address record to exactly that address, or if public DNS fails on
# the host or via dnsmasq at 10.100.0.1.
{ config, lib, pkgs, ... }:
let
  parseAddress = entry:
    let
      parts = lib.splitString "/" entry;
    in
    if builtins.length parts == 3 && builtins.head parts == "" then
      {
        name = builtins.elemAt parts 1;
        ip = builtins.elemAt parts 2;
      }
    else
      throw "homelab-selfcheck: dnsmasq address '${entry}' is not /name/ip";

  records = map parseAddress (config.services.dnsmasq.settings.address or [ ]);

  script = pkgs.writeShellScript "homelab-selfcheck" ''
    set -u
    fail=0
    # getent follows nsswitch. mdns4_minimal [NOTFOUND=return] sits in front of
    # resolve, so a public name can come back empty while resolvectl has it.
    a_records() {
      resolvectl query --type=A --legend=no "$1" | awk '{print $4}' | sort -u | paste -sd' ' -
    }
    check() {
      local name="$1" expect="$2" got
      got=$(a_records "$name")
      if [[ "$got" == "$expect" ]]; then
        printf 'ok %s -> %s\n' "$name" "$expect"
      else
        printf 'homelab-selfcheck: %s expected %s, got %s\n' "$name" "$expect" "''${got:-<none>}" >&2
        fail=1
      fi
    }
    ${lib.concatMapStrings (r: ''
      check ${lib.escapeShellArg r.name} ${lib.escapeShellArg r.ip}
    '') records}
    public() {
      local name="$1" got
      got=$(a_records "$name")
      if [[ -n "$got" ]]; then
        printf 'ok %s -> %s\n' "$name" "$got"
      else
        printf 'homelab-selfcheck: %s did not resolve\n' "$name" >&2
        fail=1
      fi
    }
    public example.com
    dig_at() {
      local server="$1" name="$2" expect="''${3:-}" got
      got=$(dig @"$server" "$name" A +short +time=3 +tries=1 | sort -u | paste -sd' ' -)
      if [[ -n "$expect" && "$got" == "$expect" ]]; then
        printf 'ok @%s %s -> %s\n' "$server" "$name" "$got"
      elif [[ -z "$expect" && -n "$got" ]]; then
        printf 'ok @%s %s -> %s\n' "$server" "$name" "$got"
      else
        printf 'homelab-selfcheck: @%s %s expected %s, got %s\n' \
          "$server" "$name" "''${expect:-<any>}" "''${got:-<none>}" >&2
        fail=1
      fi
    }
    dig_at 10.100.0.1 authentik.internal 10.100.0.1
    dig_at 10.100.0.1 example.com
    exit "$fail"
  '';
in
{
  config = lib.mkIf (config.services.dnsmasq.enable && records != [ ]) {
    systemd.services.homelab-selfcheck = {
      description = "Resolve this host's dnsmasq names";
      wantedBy = [ "multi-user.target" ];
      after = [ "dnsmasq.service" "systemd-resolved.service" ];
      requires = [ "dnsmasq.service" "systemd-resolved.service" ];
      path = [
        pkgs.systemd
        pkgs.gawk
        pkgs.coreutils
        pkgs.dig
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = false;
        TimeoutStartSec = 30;
        ExecStart = script;
      };
    };
  };
}
