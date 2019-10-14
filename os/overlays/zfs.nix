self: super:
{
  zfs = super.zfsUnstable.overrideAttrs (oldAttrs: rec {
    name = "zfs-${version}";
    version = "0.8.2.vpsadminos-1910140";
    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "zfs";
      rev = "19eaccee409080051f814496c8751bc64d6d1ef2";
      sha256 = "0vx7abn09shmx7zdwkrds8x3a7fqhrq545b4xil2qz2ynfrl173p";
    };
  });
}
