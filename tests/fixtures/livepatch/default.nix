{
  pkgs ? import (builtins.getFlake (toString ../../..)).inputs.nixpkgs {
    config = { };
    overlays = [ (import ../../../os/overlays/packages.nix) ];
  },
}:
let
  # Independently checked after the completed local build and matched against
  # the passing AMD lifecycle artifact. Never derive this pin from the fixture.
  correctedSha256 = "bea178e9f7fce5db246f2bded1c2b964f0cbfc4e41c80c9328f3b11857d0d3f9";
  candidateSystem = import ../../../os {
    importedPkgs = pkgs;
    configuration = ../../configs/vpsadminos/livepatch-6.12.95-boot-base.nix;
  };
  candidateModule = "${candidateSystem.config.system.build.livePatches}/lib/modules/6.12.95/extra/livepatch_7.ko";

  # These are the released module bytes, not rebuilds from today's sources.
  mkExactModule =
    name: archive: sha256:
    pkgs.runCommand "${name}-exact-predecessor.ko" { nativeBuildInputs = [ pkgs.zstd ]; } ''
      zstd -q -dc ${archive} > "$out"
      printf '%s  %s\n' '${sha256}' "$out" | sha256sum --check --status
    '';
in
{
  inherit correctedSha256;
  corrected = pkgs.runCommand "livepatch_7-exact-candidate.ko" { } ''
    printf '%s  %s\n' '${correctedSha256}' '${candidateModule}' | sha256sum --check --status
    ln -s '${candidateModule}' "$out"
  '';
  releasedV5 =
    mkExactModule "livepatch_5" ./released-v5-b31f6440.ko.zst
      "b31f64403d9d55f62e3d59e4bbefcbddcbda4fa66a2dc0689f9bb7cd7e927984";
  shippedV6 =
    mkExactModule "livepatch_6" ./shipped-v6-960b13f1.ko.zst
      "960b13f1b461b95e29cccff58ddf0d3f3badf151046eb46eba36a9c8c7e5efe3";
}
