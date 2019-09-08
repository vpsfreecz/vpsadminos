self: super:
{
  zfs = super.zfsUnstable.overrideAttrs (oldAttrs: rec {
    name = "zfs-${version}";
    version = "0.8.2.vpsadminos";
    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "zfs";
      rev = "88edd3b94c3b4a926a94d0173a055a0bca053ea0";
      sha256 = "0x2vjij6fp7k96b68f0z673k3akwl732i8ij0aalp0z576c2yily";
    };
  });
}
