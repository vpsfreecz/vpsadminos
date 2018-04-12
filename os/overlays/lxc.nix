self: super:
{
  lxc = super.lxc.overrideAttrs (oldAttrs: rec {
    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "lxc";
      rev = "dd9a075d628eeeed1bab86e0673ffc8cfc2796be";
      sha256 = "064px8p4ajbk4cf435s62j7zc6zwn97zm6jxv0xkf7fxi3p5yfhg";
    };
  });
}
