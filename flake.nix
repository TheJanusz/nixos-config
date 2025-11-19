{
  description = "System configuration fot the Asus TUF F16 laptop";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
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
        nixosConfigurations = {
	  myNixos = nixpkgs.lib.nixosSystem {
	    specialArgs = { inherit system; };

	    modules = [
              {
                nixpkgs.overlays = [ overlay-unstable ];
              }
	      ./desktop/nixos/configuration.nix
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
	
      };
}

