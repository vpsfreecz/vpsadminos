self: super:
{
  zfs = super.zfsUnstable.overrideAttrs (oldAttrs: rec {
    name = "zfs-${version}";
    version = "0.8.2.vpsadminos-1911120";
    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "zfs";
      rev = "aca6706986d2d1e6c19fbe1a908ed43cc85d36b0";
      sha256 = "sha256:0zccl7qsda97ry4gmhjy6qy8mc39gam2nxihq1kzqchd9jd6za4y";
    };
  });
}
