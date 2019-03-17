self: super:
{
  zfs = super.zfsUnstable.overrideAttrs (oldAttrs: rec {
    name = "zfs-${version}";
    version = "0.8.0-rc3.vpsfree";
    src = super.fetchFromGitHub {
      owner = "vpsfree";
      repo = "zfs";
      rev = "0638341c4bdfd3f6147ffa7936caa61c5e5edcb8";
      sha256 = "0sma5p5fibyscmamar81sjwzi1vi516dd77bdb913ivnxfnw6lzx";
    };
  });
}
