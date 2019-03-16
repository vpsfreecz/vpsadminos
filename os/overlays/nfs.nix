self: super:
{
  nfs-utils = super.nfs-utils.overrideAttrs (oldAttrs: rec {
    patches = oldAttrs.patches ++ [
      ../packages/nfs-utils/patches/000-export_option_root_uid.patch
    ];
  });
}
