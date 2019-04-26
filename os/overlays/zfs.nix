self: super:
{
  zfs = super.zfsUnstable.overrideAttrs (oldAttrs: rec {
    name = "zfs-${version}";
    version = "0.8.0-rc4.vpsfree";
    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "zfs";
      rev = "8f776f88e8a21e59fa668ae9768b93b0e9f6e1b1";
      sha256 = "132p3xdg9f0dflygfyfndqqavl6pi78sakm0r5zi72wnlx1nnwbv";
    };
  });
}
