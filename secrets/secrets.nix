
let
  system1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBqTZ/frLgist2Q5CKKUs1+0lpJ6TLAejdMH92DRq/U7 root@nixos";
  systems = [ system1 ];
  user1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBvJ56LJONXj+4+WBYzJoo7Ohxl2PPZD5zLNzpAcu9ST pietrzyk.janusz1@gmail.com";
  users = [ user1 ];
in {
  "secret1.age".publicKeys = [ user1 system1 ];
  "wg-privatekey.age".publicKeys = [ user1 system1 ];
  "authentik-env.age".publicKeys = [ user1 system1 ];
  "wildcard.internal.crt.age".publicKeys = [ user1 system1 ];
  "wildcard.internal.key.age".publicKeys = [ user1 system1 ];
  "wg-peers.conf.age".publicKeys = [ user1 system1 ];
}
