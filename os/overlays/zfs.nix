self: super:
{
  zfs = super.zfsUnstable.overrideAttrs (oldAttrs: rec {
    name = "zfs-${version}";
    version = "2018-05-14.vpsfree";
    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "zfs";
      rev = "326024d7421f205a5494bc263e5e681d96f0e3c2";
      sha256 = "14b8qw8qnah50g8d95an5jabn1idfj0glb9nx9r6zr4dppx08z0z";
    };
  });
}
