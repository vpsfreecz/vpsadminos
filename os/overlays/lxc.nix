self: super:
{
  lxc = super.lxc.overrideAttrs (oldAttrs: rec {
    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "lxc";
      rev = "6f94c2d2b1212756f6449c32928d485d1869d05d";
      sha256 = "0r88qw3lrankykcmml46h3gd9hjmp3vamh372k58w0160vyqzqjy";
    };
  });
}
