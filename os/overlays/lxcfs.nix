self: super:
{
  lxcfs = super.lxcfs.overrideAttrs (oldAttrs: rec {
    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "lxcfs";
      rev = "75444167fef58175d11a61ef78c6d814724c163d";
      sha256 = "0mq3sxpjx1a4b5gwc6js122fza0ql8y525ygjchki97k7lrnqr1f";
    };

    postFixup = ''
      # liblxcfs.so is reloaded with dlopen()
      patchelf --set-rpath "/run/current-system/sw/lib/lxcfs:$(patchelf --print-rpath "$out/bin/lxcfs"):$out/lib" "$out/bin/lxcfs"
    '';
  });
}
