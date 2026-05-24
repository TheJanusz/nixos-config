{ config, pkgs, lib, osConfig, ... }:

{
  # Home Manager needs a bit of information about you and the paths it should
  # manage.
  home.username = "lord";
  home.homeDirectory = "/home/lord";

  # This value determines the Home Manager release that your configuration is
  # compatible with. This helps avoid breakage when a new Home Manager release
  # introduces backwards incompatible changes.
  #
  # You should not change this value, even if you update Home Manager. If you do
  # want to update the value, then make sure to first check the Home Manager
  # release notes.
  home.stateVersion = "25.11"; # Please read the comment before changing.

  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
    "discord"
    "megasync"
    "obsidian"
    "makemkv"
  ];

  programs.yazi = {
    enable = true;
    shellWrapperName = "y";
    settings.yazi = {
      opener.edit = [
        { run = "nvim \"$@\""; block = true; }
      ];
    };
  };

  # Adding this explicitly for VLC to run some blu-ray menus
  programs.java = {
    enable = true;
    package = pkgs.jdk11;
  };

  # The home.packages option allows you to install Nix packages into your
  # environment.
  home.packages = with pkgs; [
    (writeScriptBin "split-cue" (builtins.readFile ../bin/split.rb))
    (writeScriptBin "shift-track-numbers" (builtins.readFile ../bin/shift-track-numbers.rb))
    bitwarden-desktop

    # Game dev
    blender
    godot

    nautilus # file manager
    btop # system monitoring TUI
    clipse # clipboard TUI
    gtypist # typing practice
    # megasync
    # megacmd
    obsidian # Notetaking
    qownnotes # Alternative notetaking
    libreoffice-qt6-fresh
    nextcloud-client
    rofi # application launcher
    subtitleedit
    devenv
    ollama
    freetube
    (ruby_4_0.withPackages (ps: with ps; [ taglib-ruby ]))
    
    # testing
    gimp
    inkscape
    rizin # decompilation / binary analysis
    # ares-cli # WebOS management
    libxml2 # Just for xmllint
    zlib
    # mp3splt # Audio file splitting by .cue files. Useful for audiobooks. Not in unstable.
    #lgogdownloader
    #nerdfonts.override { fonts = [ "BigBlueTerminal" ]; }
    # # Adds the 'hello' command to your environment. It prints a friendly
    # # "Hello, world!" when run.
    # pkgs.hello

    # # It is sometimes useful to fine-tune packages, for example, by applying
    # # overrides. You can do that directly here, just don't forget the
    # # parentheses. Maybe you want to install Nerd Fonts with a limited number of
    # # y"fonts?
    # (pkgs.nerdfonts.override { fonts = [ "FantasqueSansMono" ]; })

    # # You can also create simple shell scripts directly inside your
    # # configuration. For example, this adds a command 'my-hello' to your
    # # environment:
    # (pkgs.writeShellScriptBin "my-hello" ''
    #   echo "Hello, ${config.home.username}!"
    # '')
  ];

  programs.direnv = {
    enable = true;
    enableZshIntegration = true;
    nix-direnv.enable = true;
  };

  # Home Manager is pretty good at managing dotfiles. The primary way to manage
  # plain files is through 'home.file'.
  home.file = {
    # # Building this configuration will create a copy of 'dotfiles/screenrc' in
    # # the Nix store. Activating the configuration will then make '~/.screenrc' a
    # # symlink to the Nix store copy.
    # ".screenrc".source = dotfiles/screenrc;

    # # You can also set the file content immediately.
    # ".gradle/gradle.properties".text = ''
    #   org.gradle.console=verbose
    #   org.gradle.daemon.idletimeout=3600000
    # '';
    ".config/vlc/libaacs.so.0" = {
      source = "${pkgs.makemkv}/lib/libmmbd.so.0";
      onChange = ''
        chmod 788 $out
      '';
    };
    ".config/vlc/libbdplus.so.0".source = "${pkgs.makemkv}/lib/libmmbd.so.0";
    ".config/vlc/libmmbd.so.0".source = "${pkgs.makemkv}/lib/libmmbd.so.0";
  };

  # Home Manager can also manage your environment variables through
  # 'home.sessionVariables'. These will be explicitly sourced when using a
  # shell provided by Home Manager. If you don't want to manage your shell
  # through Home Manager then you have to manually source 'hm-session-vars.sh'
  # located at either
  #
  #  ~/.nix-profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  ~/.local/state/nix/profiles/profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  /etc/profiles/per-user/lord/etc/profile.d/hm-session-vars.sh
  #
  home.sessionVariables = {
    EDITOR = "nvim";
    LD_LIBRARY_PATH = lib.mkAfter "$HOME/.config/vlc";
    LIBAACS_PATH = "$HOME/.config/vlc/libaacs.so.0";
    LIBBDPLUS_PATH = "$HOME/.config/vlc/libbdplus.so.0";
  };

  # home.sessionPath = [
  #   "#{home.homeDirectory}/nixos-config/bin"
  # ];

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  imports = [
    ../modules/home/browser.nix
    ../modules/home/communication.nix
    ../modules/home/git.nix
    ../modules/home/hyprland.nix
    ../modules/home/nvim.nix
    ../modules/home/ripping.nix
    ../modules/home/video_production.nix
    ../modules/home/waybar.nix
    ../modules/home/zsh.nix
  ];
}
