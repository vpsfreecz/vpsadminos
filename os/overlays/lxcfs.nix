self: super:
{
  lxcfs = super.lxcfs.overrideAttrs (oldAttrs: rec {
    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "lxcfs";
      rev = "57f8b82ecebac984ea76bd5cae1bb7bad3a10acd";
      sha256 = "02a1l2xkidbgpfbb6az5r61k082n3nk8vk4xs99j1p3d68wsvipd";
    };

    postFixup = ''
      # liblxcfs.so is reloaded with dlopen()
      patchelf --set-rpath "/run/current-system/sw/lib/lxcfs:$(patchelf --print-rpath "$out/bin/lxcfs"):$out/lib" "$out/bin/lxcfs"
    '';
  });
}
