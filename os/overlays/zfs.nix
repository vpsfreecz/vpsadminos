self: super:
{
  zfs = super.zfsUnstable.overrideAttrs (oldAttrs: rec {
    name = "zfs-${version}";
    version = "2017-11-16.aither";
    src = super.fetchFromGitHub {
      owner = "aither64";
      repo = "zfs";
      rev = "16148803eb0adb351b9a2c083729db9aca26f7bc";
      sha256 = "0q2d93k4kg4y9ljk12qlkzlrv6sqild1ki2p9y794fawy9c1py6g";
    };
  });
}
