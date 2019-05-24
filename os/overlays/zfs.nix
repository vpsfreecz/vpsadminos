self: super:
{
  zfs = super.zfsUnstable.overrideAttrs (oldAttrs: rec {
    name = "zfs-${version}";
    version = "0.8.0.vpsadminos";
    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "zfs";
      rev = "d22d5bea8a1b4b25d4515b10297f02de3678ca95";
      sha256 = "1afgdc5h3xwxhrmb19ai0rk0mb8y7ivbgpiqkcmflmbhvcc2bvys";
    };
  });
}
