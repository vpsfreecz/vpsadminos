self: super:
{
  zfs = super.zfsUnstable.overrideAttrs (oldAttrs: rec {
    name = "zfs-${version}";
    version = "0.8.0-rc3.vpsfree";
    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "zfs";
      rev = "fa11744a4ce05e6c3c7526335b46be5901751a19";
      sha256 = "0zyl2qm6nq4nv3rpxhqmkp8sf57256l01ni5s96kymfmjr46pzwf";
    };
  });
}
