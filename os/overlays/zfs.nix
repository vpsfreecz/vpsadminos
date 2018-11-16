self: super:
{
  zfs = super.zfsUnstable.overrideAttrs (oldAttrs: rec {
    name = "zfs-${version}";
    version = "0.8.0-rc2.vpsfree";
    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "zfs";
      rev = "3893c5629a6622d452d813dab50b039d843904fe";
      sha256 = "10wj4xxcqmm36j01chqpjjnh2fiskps8v5ij005cx4bqfxrvj5mj";
    };
  });
}
