self: super:
{
  lxcfs = super.lxcfs.overrideAttrs (oldAttrs: rec {
    version = "4.0.4";

    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "lxcfs";
      rev = "827481079b2bc509f1c26945b1dbb73585297270";
      sha256 = "sha256:04sahy39nqqkwpbw2rws7zrl32rglnihfpbbhkyr0gb0jxzd6h5q";
    };

    postFixup = ''
      # liblxcfs.so is reloaded with dlopen()
      patchelf --set-rpath "/run/current-system/sw/lib/lxcfs:$(patchelf --print-rpath "$out/bin/lxcfs"):$out/lib" "$out/bin/lxcfs"
    '';
  });
}
