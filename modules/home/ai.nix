{ config, pkgs, ... }:

{
  # nixpkgs aider 0.86.1 crashes while loading if litellm's exception
  # classes drift (VectorStoreSearchError was added; RouterRateLimitError
  # was removed). Treat unknown litellm errors as retryable and skip names
  # this litellm build does not export.
  home.packages = with pkgs; [
    llama-cpp
    (aider-chat-with-playwright.overridePythonAttrs (old: {
      postPatch = (old.postPatch or "") + ''
        python3 - <<'PY'
        from pathlib import Path
        path = Path("aider/exceptions.py")
        text = path.read_text()
        old = """    def _load(self, strict=False):
                import litellm

                for var in dir(litellm):
                    if var.endswith("Error"):
                        if var not in self.exception_info and var not in [ "ErrorEventError" ]:
                            raise ValueError(f"{var} is in litellm but not in aider's exceptions list")

                for var in self.exception_info:
                    ex = getattr(litellm, var)
                    self.exceptions[ex] = self.exception_info[var]
        """
        new = """    def _load(self, strict=False):
                import litellm

                # litellm adds and removes exception classes independently of aider.
                # Register unknown ones as retryable, and skip names this build does
                # not export. ErrorEventError ends with Error but is not an exception.
                for var in dir(litellm):
                    if not var.endswith("Error") or var == "ErrorEventError":
                        continue
                    ex = getattr(litellm, var, None)
                    if not isinstance(ex, type) or not issubclass(ex, BaseException):
                        continue
                    if var not in self.exception_info:
                        self.exception_info[var] = ExInfo(var, True, None)

                for var, info in list(self.exception_info.items()):
                    ex = getattr(litellm, var, None)
                    if not isinstance(ex, type) or not issubclass(ex, BaseException):
                        continue
                    self.exceptions[ex] = info
        """
        if old not in text:
            raise SystemExit("aider/exceptions.py _load() did not match; package was not patched")
        path.write_text(text.replace(old, new, 1))
        PY
      '';
    }))
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

  # Override per run with --model or in-chat /model.
  # Weights: ollama pull qwen2.5-coder:7b
  home.sessionVariables.OLLAMA_API_BASE = "http://127.0.0.1:11434";

  home.file.".aider.conf.yml".text = ''
    model: ollama_chat/qwen2.5-coder:7b
    auto-commits: false
    dirty-commits: false
  '';
}
