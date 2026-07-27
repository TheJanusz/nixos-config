
let
  system1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBqTZ/frLgist2Q5CKKUs1+0lpJ6TLAejdMH92DRq/U7 root@nixos";
  homelab = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMVAb8zagL2ZQz58Fe6UiGKbkplI3tk77QAGx/6JcRwf root@nixos";
  systems = [ system1 ];
  user1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBvJ56LJONXj+4+WBYzJoo7Ohxl2PPZD5zLNzpAcu9ST pietrzyk.janusz1@gmail.com";
  users = [ user1 ];
in {
  "secret1.age".publicKeys = [ user1 system1 homelab ];
  "wg-privatekey.age".publicKeys = [ user1 system1 homelab ];
  "authentik-env.age".publicKeys = [ user1 system1 homelab ];
  "wildcard.internal.crt.age".publicKeys = [ user1 system1 homelab ];
  "wildcard.internal.key.age".publicKeys = [ user1 system1 homelab ];
  "wg-peers.conf.age".publicKeys = [ user1 system1 homelab ];
  "wg-client-privatekey.age".publicKeys = [ user1 system1 ];
}
