self: super:
{
  lxcfs = super.lxcfs.overrideAttrs (oldAttrs: rec {
    version = "4.0.11";

    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "lxcfs";
      rev = "f3ac5f4828475bfa925e3d455dea5be6a4eaf40c";
      sha256 = "sha256-0jYnofZPq7/uwOMQkjgFIHmkCm92o+D1b4J18fSp31c=";
    };

    postFixup = ''
      # liblxcfs.so is reloaded with dlopen()
      patchelf --set-rpath "/run/current-system/sw/lib/lxcfs:$(patchelf --print-rpath "$out/bin/lxcfs"):$out/lib" "$out/bin/lxcfs"
    '';
  });
}
