{ config, pkgs, lib, ... }:
let
  
in
{
  imports = [
  ];

  programs.nixvim = {
    enable = true;

    colorschemes.tokyonight.enable = true;
    opts = {
      number = true;
      relativenumber = true;
      shiftwidth = 2;
      expandtab = true;
      scrolloff = 10;
      smartindent = true;
      smarttab = true;
      undofile = true;
      wrap = true;
    };

    plugins = {
      ccc = {
        enable = true;
        settings.highlighter.auto_enable = true;
        settings.highlight_mode = "bg";
        settings.lsp = true;
        settings.inputs = [
          "ccc.input.rgb"
        ];
        settings.outputs = [
          "ccc.output.hex"
          "ccc.output.css_rgb"
        ];
        settings.pickers = [
          "ccc.picker.hex"
          "ccc.picker.css_rgb"
        ];
      };
      comment.enable = true;
      git-conflict.enable = true;
      lualine.enable = true;
      mini-snippets = {
        enable = true;
        settings = {
        };
      };
      nix.enable = true;
      nvim-autopairs.enable = true;
      # obsidian.enable = true;
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
          standardrb.enable = true;
          tailwindcss.enable = true;
	};
      };
    };
    extraPlugins = [
      pkgs.vimPlugins.boole-nvim
    ];
  };
}
