self: super:
{
  zfs = super.zfsUnstable.overrideAttrs (oldAttrs: rec {
    name = "zfs-${version}";
    version = "0.8.2.vpsadminos";
    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "zfs";
      rev = "91a52106dcb8b280670e36e014e0df66d407b56d";
      sha256 = "06vqwj9r3m260wy0vbw8aa4l3nk6l4ddzmcr9gf68nxmp30yn71j";
    };
  });
}
