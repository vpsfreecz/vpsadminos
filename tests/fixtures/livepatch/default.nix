{ pkgs }:
let
  # These are the released module bytes, not rebuilds from today's sources.
  mkExactModule =
    name: archive: sha256:
    pkgs.runCommand "${name}-exact-predecessor.ko" { nativeBuildInputs = [ pkgs.zstd ]; } ''
      zstd -q -dc ${archive} > "$out"
      printf '%s  %s\n' '${sha256}' "$out" | sha256sum --check --status
    '';
in
{
  releasedV5 =
    mkExactModule "livepatch_5" ./released-v5-b31f6440.ko.zst
      "b31f64403d9d55f62e3d59e4bbefcbddcbda4fa66a2dc0689f9bb7cd7e927984";
  shippedV6 =
    mkExactModule "livepatch_6" ./shipped-v6-960b13f1.ko.zst
      "960b13f1b461b95e29cccff58ddf0d3f3badf151046eb46eba36a9c8c7e5efe3";
}
