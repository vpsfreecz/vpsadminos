self: super:
{
  lxcfs = super.lxcfs.overrideAttrs (oldAttrs: rec {
    version = "4.0.4";

    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "lxcfs";
      rev = "d8231aeb879f124056defbd4aba7a05f89f5bc49";
      sha256 = "sha256:1k86an27c7h6fr1xjryqvkhncp0i5yq7q6ybqhs8lig0q7igfq8i";
    };

    postFixup = ''
      # liblxcfs.so is reloaded with dlopen()
      patchelf --set-rpath "/run/current-system/sw/lib/lxcfs:$(patchelf --print-rpath "$out/bin/lxcfs"):$out/lib" "$out/bin/lxcfs"
    '';
  });
}
