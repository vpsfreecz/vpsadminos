self: super:
{
  zfs = super.zfsUnstable.overrideAttrs (oldAttrs: rec {
    name = "zfs-${version}";
    version = "2018-04-13.vpsfree";
    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "zfs";
      rev = "8ee1788253e766f43c26b9790a357cf00e7a9ede";
      sha256 = "16did4bzx5hk6qgylxxvx0idawi8s0kw8l71rqkr311k1qgvah94";
    };
  });
}
