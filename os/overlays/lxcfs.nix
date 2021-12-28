self: super:
{
  lxcfs = super.lxcfs.overrideAttrs (oldAttrs: rec {
    version = "4.0.11";

    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "lxcfs";
      rev = "783bf0937c27e4091e3393a4ce2c564c871de22f";
      sha256 = "sha256:1j8vb93f1la3c50wwzw1s8z2vqk8nz0kl2cin99511j0f7yc5iyl";
    };

    postFixup = ''
      # liblxcfs.so is reloaded with dlopen()
      patchelf --set-rpath "/run/current-system/sw/lib/lxcfs:$(patchelf --print-rpath "$out/bin/lxcfs"):$out/lib" "$out/bin/lxcfs"
    '';
  });
}
