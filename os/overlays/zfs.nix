self: super:
{
  zfs = super.zfsUnstable.overrideAttrs (oldAttrs: rec {
    name = "zfs-${version}";
    version = "0.8.0-rc5.vpsfree";
    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "zfs";
      rev = "40a7e41454a7092238417849e72c9deb0b7be12a";
      sha256 = "1mipcgd12aprakf2xqy8ir8n2k6rmkfx5v9p8vhjk69ysrhm8fc4";
    };
  });
}
