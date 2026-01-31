{
  description = "System configuration fot the Asus TUF F16 laptop";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      #inputs.nixpkgs.follows = "nixpkgs";
      inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    };
    nixvim = {
      url = "github:nix-community/nixvim";
      #inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, home-manager, nixvim, ... }@inputs:
  let
    system = "x86_64-linux";
    overlay-unstable = final: prev: {
      unstable = import nixpkgs-unstable {
        inherit (final) system config;
      };
    };
    pkgs = import nixpkgs-unstable {
      inherit system;
      config = {
        allowUnfree = true;
      };
    };
  in
  {
        # repl = { inherit inputs; pkgs = import nixpkgs-unstable { system = "x86_64-linux"; }; };
        nixosConfigurations = {
          myNixos = nixpkgs.lib.nixosSystem {
            specialArgs = { inherit system; };

            modules = [
              {
                nixpkgs.overlays = [ overlay-unstable ];
              }
              ./desktop_nvme/nixos/configuration.nix
            ];
          };
        };
        homeConfigurations."lord" = home-manager.lib.homeManagerConfiguration {
          inherit pkgs;

          # Specify your home configuration modules here, for example,
          # the path to your home.nix.
          modules = [
            ./home-manager/home.nix
            nixvim.homeModules.nixvim
          ];

          # Optionally use extraSpecialArgs
          # to pass through arguments to home.nix
        };	
        devShells.${system}.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            ruby_4_0
            gcc
            gnumake
            pkg-config
            zlib
            openssl
            libyaml
            gmp
            readline
            rustc
            fish
          ];
          nativeBuildInputs = [ pkgs.pkg-config ];
          env = { SHELL = "${pkgs.fish}/bin/fish"; };
          shellHook = ''
            exec fish -C '
            set -gx GEM_HOME $PWD/.gem
            set -gx PATH $GEM_HOME/bin $PATH
            bundle config set path $GEM_HOME
            if not type -q rails
            echo "Rails not found. Installing Rails..."
            gem install rails
            end
            if not test -d "$GEM_HOME/gems"
            echo "Installing Ruby gems..."
            bundle install
            end
            echo "Ruby version: $(ruby --version)"
            echo "Rails version: $(rails --version)"
            '
          '';
        };
      };
    }

