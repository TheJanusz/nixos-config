{
  description = "System configuration fot the be_quiet! desktop";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    };
    nixvim = {
      url = "github:nix-community/nixvim";
    };
    agenix.url = "github:ryantm/agenix";
    authentik-nix.url = "github:nix-community/authentik-nix";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, home-manager, nixvim, agenix, authentik-nix, ... }@inputs:
  let
    system = "x86_64-linux";
    pkgs-stable = nixpkgs.legacyPackages.${system};
    overlay-unstable = final: prev: {
      unstable = import nixpkgs-unstable {
        inherit (final) system config;
      };
    };
    openblas-fix = final: prev: {
      openblas = prev.openblas.overrideAttrs (oldAttrs: {
        doCheck = false;
      });
    };
    pkgs = import nixpkgs-unstable {
      inherit system;
      config = {
        allowUnfree = true;
      };
    };
  in
  {
    nixosConfigurations = {
      myNixos = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit system; };

        modules = [
          {
            nix.package = pkgs.nixVersions.latest;
            nixpkgs.overlays = [ overlay-unstable openblas-fix ];
          }
          # authentik-nix.nixosModules.default
          ./desktop_nvme/nixos/configuration.nix
          agenix.nixosModules.default
        ];
        specialArgs = { inherit inputs; };
      };
    };

    homeConfigurations."lord" = home-manager.lib.homeManagerConfiguration {
      inherit pkgs;

      extraSpecialArgs = { inherit pkgs-stable; };

      # Specify your home configuration modules here, for example,
      # the path to your home.nix.
      modules = [
        ./home-manager/home.nix
        nixvim.homeModules.nixvim
      ];

      # Optionally use extraSpecialArgs
      # to pass through arguments to home.nix
    };

    # devShells.${system}.default = pkgs.mkShell {
    #   buildInputs = with pkgs; [
    #     ruby_4_0
    #     gcc
    #     gnumake
    #     pkg-config
    #     zlib
    #     openssl
    #     libyaml
    #     gmp
    #     readline
    #     rustc
    #     fish
    #   ];
    #   nativeBuildInputs = [ pkgs.pkg-config ];
    #   env = { SHELL = "${pkgs.fish}/bin/fish"; };
    #   shellHook = ''
    #         exec fish -C '
    #         set -gx GEM_HOME $PWD/.gem
    #         set -gx PATH $GEM_HOME/bin $PATH
    #         bundle config set path $GEM_HOME
    #         if not type -q rails
    #         echo "Rails not found. Installing Rails..."
    #         gem install rails
    #         end
    #         if not test -d "$GEM_HOME/gems"
    #         echo "Installing Ruby gems..."
    #         bundle install
    #         end
    #         echo "Ruby version: $(ruby --version)"
    #         echo "Rails version: $(rails --version)"
    #         '
    #   '';
    # };
  };
}

