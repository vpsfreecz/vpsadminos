self: super:
{
  lxc = super.lxc.overrideAttrs (oldAttrs: rec {
    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "lxc";
      rev = "44b80445dd8c6b8218afb62c56f752b418a858e8";
      sha256 = "19jkqmnr4ss5jmjdk7dr05bavd0d7jjimzlhfizr93wz7glzwp20";
    };
  });
}
