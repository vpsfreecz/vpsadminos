self: super:
{
  zfs = super.zfsUnstable.overrideAttrs (oldAttrs: rec {
    name = "zfs-${version}";
    version = "0.8.0-rc5.vpsfree";
    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "zfs";
      rev = "5bb0af8289de1a1e660bb1bd6263cd910eceac63";
      sha256 = "0wgwxhkf9di67jd5hyj2yylb9016iv90hlqb5xsimn0amfbdm15q";
    };
  });
}
