self: super:
{
  zfs = super.zfsUnstable.overrideAttrs (oldAttrs: rec {
    name = "zfs-${version}";
    version = "0.8.2.vpsadminos-1910150";
    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "zfs";
      rev = "3461a18c3f1830e6085126ec3e6074e489ae5741";
      sha256 = "1d270l9dl9j8jjffhw09ymyafdg97fc8r6mj4an51sga10bwppcm";
    };
  });
}
