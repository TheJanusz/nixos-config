{ config, lib, pkgs, ... }:

let
  vaapiInGraphics = builtins.filter (p: (p.pname or "") == "nvidia-vaapi-driver") config.hardware.graphics.extraPackages;
in
{
  multipleAllowedUnfreePredicate = [ "nvidia-x11" "nvidia-settings" "cuda-merged" "cuda_cuobjdump" "cuda_gdb" "cuda_nvcc" "cuda_nvdisasm" "cuda_nvprune" "cuda_cccl" "cuda_cudart" "cuda_cupti" "cuda_cuxxfilt" "cuda_nvml_dev" "cuda_nvrtc" "cuda_nvtx" "cuda_profiler_api" "cuda_sanitizer_api" "libcublas" "libcufft" "libcurand" "libcusolver" "libnvjitlink" "libcusparse" "libnpp" ];
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.graphics.enable = true;
  hardware.keyboard.zsa.enable = true;
  # NixOS nvidia.nix already adds pkgs.nvidia-vaapi-driver when videoAcceleration
  # is on (default). Pin 0.0.18 via overlay so that copy is Chromium-compatible
  # instead of appending a second .so into graphics-drivers.
  nixpkgs.overlays = [
    (_final: prev: {
      nvidia-vaapi-driver = prev.nvidia-vaapi-driver.overrideAttrs (_old: {
        version = "0.0.18";
        src = prev.fetchFromGitHub {
          owner = "elFarto";
          repo = "nvidia-vaapi-driver";
          rev = "v0.0.18";
          hash = "sha256-cEEPRKoWtNXk8LsDbkhNjnIY7UD1rfYbv2Q6ThG0YLg=";
        };
      });
    })
  ];
  assertions = [
    {
      assertion = (map (p: p.version or "") vaapiInGraphics) == [ "0.0.18" ];
      message = "Expected a single nvidia-vaapi-driver 0.0.18 in hardware.graphics.extraPackages, got: ${builtins.concatStringsSep ", " (map (p: p.name or "unknown") vaapiInGraphics)}";
    }
  ];
  hardware.nvidia = {

    # Modesetting is required.
    modesetting.enable = true;

    # Nvidia power management. Experimental, and can cause sleep/suspend to fail.
    # Enable this if you have graphical corruption issues or application crashes after waking
    # up from sleep. This fixes it by saving the entire VRAM memory to /tmp/ instead 
    # of just the bare essentials.
    powerManagement.enable = false;

    # Fine-grained power management. Turns off GPU when not in use.
    # Experimental and only works on modern Nvidia GPUs (Turing or newer).
    powerManagement.finegrained = false;

    # Use the NVidia open source kernel module (not to be confused with the
    # independent third-party "nouveau" open source driver).
    # Support is limited to the Turing and later architectures. Full list of 
    # supported GPUs is at: 
    # https://github.com/NVIDIA/open-gpu-kernel-modules#compatible-gpus 
    # Only available from driver 515.43.04+
    open = true;

    # Enable the Nvidia settings menu,
	# accessible via `nvidia-settings`.
    nvidiaSettings = true;

    # Optionally, you may need to select the appropriate driver version for your specific GPU.
    package = config.boot.kernelPackages.nvidiaPackages.stable; 
  };
  environment.systemPackages = with pkgs; [
    libva
    libva-utils
  ];

  environment.sessionVariables = {
    LIBVA_DRIVER_NAME = "nvidia";
    NVD_BACKEND = "direct";
    __GLX_VENDOR_LIBRARY_NAME = "nvidia";
  };
}
