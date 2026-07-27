{ config, pkgs, lib, ... }:
let
  
in
{
  imports = [
  ];

  home.packages = with pkgs; [
    ripgrep-all
  ];

  programs.nixvim = {
    enable = true;

    keymaps = [
      {
        action = ":%s/^\\s*TRACK\\s\\+\\zs\\d\\+/\\=printf('%02d', str2nr(submatch(0)) + 1)/g<CR>";
        key = "<leader>cueplus<CR>";
        options = { silent = true; };
      }
    ];
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
      emmet.enable = true;
      lualine.enable = true;
      mini-snippets = {
        enable = true;
        settings = {
        };
      };
      nix.enable = true;
      nvim-autopairs.enable = true;
      obsidian = {
        enable = false; # Need to figure out how to configure it properly
        settings = {
        };
      };
      telescope.enable = true;
      treesitter.enable = true;
      web-devicons = {
        enable = true;
      };
      lsp = {
        enable = true;
	servers = {
	  nixd.enable = true;
          ruby_lsp = {
            enable = true;
            package = pkgs.rubyPackages_4_0.ruby-lsp;
          };
          rubocop = {
            enable = true;
            package = pkgs.rubyPackages_4_0.rubocop;
            cmd = ["bin/rubocop" "--lsp" "-c" ".rubocop.yml"];
          };
          standardrb.enable = true;
          tailwindcss.enable = true;
        };
        keymaps = {
          diagnostic = {
            "<leader>j" = "goto_next";
            "<leader>k" = "goto_prev";
          };
        };
      };
    };
    extraPlugins = [
      pkgs.vimPlugins.boole-nvim
    ];
  };
}
