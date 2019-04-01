self: super:
{
  zfs = super.zfsUnstable.overrideAttrs (oldAttrs: rec {
    name = "zfs-${version}";
    version = "master.vpsfree";
    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "zfs";
      rev = "7e43bc893693dc19b16be7372f91ef27d27c29e0";
      sha256 = "0ihlr81a69jqmrc17dgf5vkh8fqpbx6mzasj2qka03bngvrh3a4c";
    };
  });
}
