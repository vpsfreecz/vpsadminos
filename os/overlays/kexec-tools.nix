self: super:
{
  kexec-tools = super.kexec-tools.overrideAttrs (oldAttrs: rec {
    pname = "kexec-tools";
    version = "2.0.25";
    src = self.fetchurl {
      urls = [
        "mirror://kernel/linux/utils/kernel/kexec/${pname}-${version}.tar.xz"
        "http://horms.net/projects/kexec/kexec-tools/${pname}-${version}.tar.xz"
      ];
      sha256 = "sha256-fOLl3vOOwE95/rEH0CJD3VhvvGhWnszwL0S606E+wH0=";
    };
    patches = [];
  });
}
