self: super:
{
  zfs = super.zfsUnstable.overrideAttrs (oldAttrs: rec {
    name = "zfs-${version}";
    version = "2018-11-05.vpsfree";
    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "zfs";
      rev = "fb0562aeca58e890618c909ed89145bdf4ad20e0";
      sha256 = "0s8007jbscyji6dr9243hawvh060d1gzcxkpd86s81n6ksbr8gx8";
    };
  });
}
