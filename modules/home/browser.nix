{ config, pkgs, ... }:
let
  #firefox = pkgs.firefox;
in
{
  #imports = [
  #];

  programs.brave = {
    enable = true;
    # package = pkgs.brave;
    extensions = [
      { id = "hnmpcagpplmpfojmgmnngilcnanddlhb"; } # Windscribe
      { id = "nngceckbapebfimnlniiiahkandclblb"; } # Bitwarden
      { id = "ponfpcnoihfmfllpaingbgckeeldkhle"; } # Enhancer for YouTube
      { id = "eimadpbcbfnmbkopoojfekhnkhdbieeh"; } # Dark Reader
      # { id = "ankepacjgoajhjpenegknbefpmfffdic"; } # disable-youtube-shorts
      { id = "lcdlignfoefnkcfejmlnegoobondbfjb"; } # Display youtube dislikes
      { id = "ndpmhjnlfkgfalaieeneneenijondgag"; } # YouTube Anti Translate
    ];
    #defaultSearchProviderEnabled = true;
    #defaultSearchProviderSearchURL = "https://startpage.com";
  };

  # programs.firefox = {
  #   enable = true;
  #   package = pkgs.firefox-devedition;
  #   configPath = "${config.xdg.configHome}/.config/mozilla/firefox";
  # };
}

