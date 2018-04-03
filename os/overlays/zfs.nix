self: super:
{
  zfs = super.zfsUnstable.overrideAttrs (oldAttrs: rec {
    name = "zfs-${version}";
    version = "2018-04-03.aither";
    src = super.fetchFromGitHub {
      owner = "aither64";
      repo = "zfs";
      rev = "57d3aed17eab10e028c6b4c965eb30721d654e5e";
      sha256 = "1cmjnb9pmag4vwvfvx4l1603q3pd2f15yhhl64sg74wa4v972d9b";
    };
  });
}
