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
      { id = "ankepacjgoajhjpenegknbefpmfffdic"; } # disable-youtube-shorts
      { id = "lcdlignfoefnkcfejmlnegoobondbfjb"; } # Display youtube dislikes
      { id = "eimadpbcbfnmbkopoojfekhnkhdbieeh"; } # Dark Reader
    ];
  };

  programs.firefox.enable = true;
}

