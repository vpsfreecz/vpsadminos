self: super:
{
  lxcfs = super.lxcfs.overrideAttrs (oldAttrs: rec {
    version = "4.0.4";

    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "lxcfs";
      rev = "e85344c76ae12dab2be08f76b8bc2c57ebf04923";
      sha256 = "sha256:0kgrw6pv62kalc4vgkn8c0c5agyh1akdxg7y6kj4ccr25kwrgpal";
    };

    postFixup = ''
      # liblxcfs.so is reloaded with dlopen()
      patchelf --set-rpath "/run/current-system/sw/lib/lxcfs:$(patchelf --print-rpath "$out/bin/lxcfs"):$out/lib" "$out/bin/lxcfs"
    '';
  });
}
