self: super:
{
  nfs-utils = super.nfs-utils.overrideAttrs (oldAttrs: rec {
    patches = oldAttrs.patches ++ [
      # Userspace counterpart to the patch introducting export option root_uid
      ../packages/nfs-utils/patches/000-export_option_root_uid.patch
    ];
  });
}
