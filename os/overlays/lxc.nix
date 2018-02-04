self: super:
{
  lxc = super.lxc.overrideAttrs (oldAttrs: rec {
    src = super.fetchFromGitHub {
      owner = "sorki";
      repo = "lxc";
      rev = "fbe92e013a569327513fc7028134a6a740a2e51e";
      sha256 = "13hnyn08yrd1m2pk2229n2lb4v7cwd3829jqgqmi201s52wz6w0b";
    };
  });
}
