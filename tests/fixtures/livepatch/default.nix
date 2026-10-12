{
  pkgs ? import (builtins.getFlake (toString ../../..)).inputs.nixpkgs {
    config = { };
    overlays = [ (import ../../../os/overlays/packages.nix) ];
  },
}:
let
  # Independently built normal package with compatible busy-RTNL NFQUEUE handover.
  # All 707 import CRCs match the boot kernel; both focused NFQUEUE cases pass.
  # Never derive this pin from the candidate selected during test execution.
  correctedSha256 = "1f34bd489e5596431f1413084829621d25a35f2b59ffe7deeec28e3dc50825f3";
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
  ipv6FragmentPartial = pkgs.stdenv.mkDerivation {
    pname = "livepatch-test-ipv6-fragment-partial";
    version = "1";
    src = ../../suite/kernel/livepatch-6.12.95;

    dontConfigure = true;

    buildPhase = ''
      "$CC" -std=gnu11 -O2 -Wall -Wextra -Werror \
        -o ipv6_fragment_partial ipv6_fragment_partial.c
    '';

    installPhase = ''
      install -Dm755 ipv6_fragment_partial \
        "$out/bin/ipv6_fragment_partial"
    '';
  };
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
