{ config, pkgs, ... }:

let
in
  {
    home.packages = with pkgs; [
      llama-cpp
      # Agent / CLI — GitHub and text
      gh          # GitHub CLI: issues, PRs, checks, gist
      jq          # Parse JSON from APIs, logs, gh, curl
      yq-go       # Same idea for YAML (command is `yq`)
      fd          # Fast file find (better than find in a repo)
      ripgrep     # `rg`; Cursor grep is separate, shell still needs this
      git-lfs     # Checkout repos that store large files in LFS
      delta       # Readable git diffs (optional; I can use plain git diff)
      # Fetch / TLS / DNS (the Fluxer-style debugging)
      curl        # HTTP; well-known, health, APIs
      unzip       # Open zip artifacts
      # Nix
      nixfmt-rfc-style  # Format .nix (command: nixfmt)
      nix-output-monitor # `nom`; clearer nix build logs
      nvd         # Diff nixos/home generations after a switch
      nix-tree    # Why is this store path in my closure?
      statix      # Lint Nix
      deadnix     # Unused Nix bindings
      # Scripts
      python3     # One-off JSON/HTTP/parse scripts in the shell
      shellcheck  # Lint bash I write or edit
      shfmt       # Format those scripts
      just        # Run project `justfile` recipes if a repo has one
    ];
  }
