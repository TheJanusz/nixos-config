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
    # Rails 8.1.4 is not in nixpkgs (that set is still 7.2). Lockfile lives in devshell/rails.
    railsGems = pkgs.bundlerEnv {
      name = "workshop-rails";
      ruby = pkgs.ruby_4_0;
      gemdir = ./devshell/rails;
      gemConfig = pkgs.defaultGemConfig;
    };
    rails = pkgs.writeShellScriptBin "rails" ''
      export GEM_PATH="${railsGems}/${pkgs.ruby_4_0.gemPath}"
      unset GEM_HOME
      unset BUNDLE_GEMFILE
      unset BUNDLE_PATH
      exec ${pkgs.ruby_4_0}/bin/ruby ${railsGems.gems.railties}/bin/rails "$@"
    '';
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
      homelab = nixpkgs.lib.nixosSystem {
      	specialArgs = { inherit system; };

	modules = [
	  {
	    nix.package = pkgs.nixVersions.latest;
	    nixpkgs.overlays = [ overlay-unstable ];
	  }
          authentik-nix.nixosModules.default
	  ./homelab/nixos/configuration.nix
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

    # Workshop shell for scaffolding an app, then leaving it.
    # Run from the directory that should contain the app:
    #   nix develop ~/nixos-config
    #   rails --version   # Rails 8.1.4
    #   rails new myapp --skip-bundle
    #   exit
    #   cd myapp && devenv init
    # --skip-bundle stays: this Ruby cannot install the new app's gems.
    # Rails 8.1 writes .ruby-version from this Ruby (4.0.7). In the new
    # project's devenv.nix:
    #   languages.ruby.enable = true;
    #   languages.ruby.versionFile = ./.ruby-version;
    # That devenv owns Bundler, native gems, and services.
    # The rails wrapper sets GEM_PATH for that process only.
    devShells.${system}.default = pkgs.mkShell {
      packages = [
        rails
        pkgs.devenv
      ];
    };
  };
}
