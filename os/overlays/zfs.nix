self: super:
{
  zfs = super.zfsUnstable.overrideAttrs (oldAttrs: rec {
    name = "zfs-${version}";
    version = "0.8.2.vpsadminos-1910190";
    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "zfs";
      rev = "ac6a30ee66181892f78d74c59dcad5bffe85d33b";
      sha256 = "sha256:148kgnbpy4klwgiah2rpiras98g3bnb3d7qp8v228mf7rw1fq2mz";
    };
  });
}
