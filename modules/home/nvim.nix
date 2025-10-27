{ config, pkgs, ... }:
let
  
in
{
  imports = [
  ];

  programs.nixvim = {
    enable = true;

    colorschemes.gruvbox.enable = true;

    plugins = {
      lualine.enable = true;
      telescope.enable = true;
      treesitter.enable = true;
      web-devicons = {
        enable = true;
      };
      lsp = {
        enable = true;
	servers = {
	  nixd.enable = true;
	  ruby_lsp.enable = true;
	  rubocop.enable = true;
	};
      };
    };
  };
}

