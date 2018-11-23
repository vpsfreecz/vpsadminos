self: super:
{
  lxcfs = super.lxcfs.overrideAttrs (oldAttrs: rec {
    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "lxcfs";
      rev = "2d7226de43e99324bddf4b4e30c9fac92ea6a4b4";
      sha256 = "1zl312dx7wc73agggi5k7whh5356s1ssyzr7scr7q147w5ncpc0a";
    };

    postFixup = ''
      # liblxcfs.so is reloaded with dlopen()
      patchelf --set-rpath "/run/current-system/sw/lib/lxcfs:$(patchelf --print-rpath "$out/bin/lxcfs"):$out/lib" "$out/bin/lxcfs"
    '';
  });
}
