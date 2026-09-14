# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, inputs, lib, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ../../modules/system/options.nix
      ../../modules/server/networking.nix
      ../../modules/system/crypt.nix
      ../../modules/server
    ];

  # After creating secrets/fluxer-env.age (see modules/server/fluxer.env.example):
  # server.fluxer.enable = true;
  # server.fluxer.uploadsDir = "/data/fluxer/uploads";
  # server.fluxer.backupDir = "/data/fluxer/backups";

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" "pipe-operators" ];
    download-buffer-size = 52428899;
    trusted-users = [ "root" "lord" ];
  };
  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.initrd.luks.devices."luks-8548272f-f58b-4058-8108-903ce904e01e".device = "/dev/disk/by-uuid/8548272f-f58b-4058-8108-903ce904e01e";

  boot.supportedFilesystems = [ "zfs" ];
  networking.hostId = "f42b14c1";
  boot.zfs.forceImportRoot = false;
  boot.zfs.requestEncryptionCredentials = true;
  boot.zfs.extraPools = [ "data" ];

  # ECC
  boot.kernelModules = [ "edac_core" "edac_mce_amd" "amd64_edac_mod " ];
  boot.extraModprobeConfig = "options edac_core edac_mc_log_ue=1 edac_mc_log_ce=1";
  hardware.rasdaemon.enable = true;

  # fileSystems."/nas" = {
  #   device = "data";
  #   fsType = "zfs";
  # };

  # Enable networking
  networking.networkmanager.enable = true;

  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      intel-compute-runtime
      vpl-gpu-rt
    ];
  };

  # Set your time zone.
  time.timeZone = "Europe/Warsaw";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "pl_PL.UTF-8";
    LC_IDENTIFICATION = "pl_PL.UTF-8";
    LC_MEASUREMENT = "pl_PL.UTF-8";
    LC_MONETARY = "pl_PL.UTF-8";
    LC_NAME = "pl_PL.UTF-8";
    LC_NUMERIC = "pl_PL.UTF-8";
    LC_PAPER = "pl_PL.UTF-8";
    LC_TELEPHONE = "pl_PL.UTF-8";
    LC_TIME = "pl_PL.UTF-8";
  };

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "pl";
    variant = "";
  };

  # Configure console keymap
  console.keyMap = "pl2";

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.lord = {
    isNormalUser = true;
    description = "Janusz";
    extraGroups = [ "networkmanager" "wheel"];
    packages = with pkgs; [];
  };

  users.users."jellyfin".extraGroups = [ "video" "render" ];
  users.users."nextcloud".extraGroups = [ "video" "render" ];

  users.groups.media = {
    gid = 1800;
    members = [ "lord" "jellyfin" ];
  };

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    home-manager
    cifs-utils
    inputs.agenix.packages.${pkgs.system}.default
    # Nextcloud Memories
    ffmpeg-headless
    go
    libvpl
    exiftool
    unzip
  #  vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
  #  wget
  ];

  environment.sessionVariables = {
    LIBVA_DRIVER_NAME = "iHD";
  };

  systemd.services.phpfpm-nextcloud.serviceConfig = {
    DeviceAllow = [ "/dev/dri/renderD128 rw" ];
    PrivateDevices = lib.mkForce false; # Must be false to access /dev/dri
  };

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  services.openssh = {
    enable = true;
    settings.AllowUsers = [ "lord" ];
  };

  server.fluxer = {
    enable = true;
    uploadsDir = "/data/binary/fluxer";
    backupDir = "/data/backups/fluxer";
  };

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.11"; # Did you read the comment?

}
