self: super:
{
  runit = super.runit.overrideAttrs (oldAttrs: rec {
    patches = [
      ../packages/runit/kexec-support.patch
      ../packages/runit/maxservices-100k.patch
    ];
  });
}
