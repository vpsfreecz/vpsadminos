self: super:
{
  zfs = super.zfsUnstable.overrideAttrs (oldAttrs: rec {
    name = "zfs-${version}";
    version = "0.8.1.vpsadminos";
    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "zfs";
      rev = "c9e6782ae63b7f9b50c1d8c96eb09a1469ad7cbf";
      sha256 = "15nswnhjwlk73a9cbrv7zk59xrnzsb3ziihpvvm9iyj1z4vc4yks";
    };
  });
}
