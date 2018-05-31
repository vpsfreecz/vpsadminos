self: super:
{
  lxcfs = super.lxcfs.overrideAttrs (oldAttrs: rec {
    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "lxcfs";
      rev = "2d383c50a997c43167e3b470860a7c655ea8a7a8";
      sha256 = "1nwj2xcvag814sdn92xkg1c0a0wrqi369dzwql8g2f3rmb4x7h0i";
    };

    postFixup = ''
      # liblxcfs.so is reloaded with dlopen()
      patchelf --set-rpath "/run/current-system/sw/lib/lxcfs:$(patchelf --print-rpath "$out/bin/lxcfs"):$out/lib" "$out/bin/lxcfs"
    '';
  });
}
