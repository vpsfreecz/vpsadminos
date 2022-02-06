self: super:
{
  bird = super.bird.overrideAttrs (oldAttrs: rec {
    patches = super.bird.patches ++
      [ ../packages/bird/disable-kif-warnings-osrtr0.patch ];
  });
}
