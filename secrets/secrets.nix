let
  system1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBqTZ/frLgist2Q5CKKUs1+0lpJ6TLAejdMH92DRq/U7 root@nixos";
  systems = [ system1 ];
  user1 = "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIN7BFunmQrEJs/vRNMVRvhSl6Dfh+nZhDGyvDdl2+31bAAAABHNzaDo= pietrzyk.janusz1@gmail.com";
  users = [ user1 ];
in {
  "secret1.age".publicKeys = [ system1 ];
  "wg-privatekey.age".publicKeys = [ system1 ];
}
