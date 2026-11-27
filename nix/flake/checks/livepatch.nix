{
  forAllSystems,
  livepatchCiTools,
  livepatchPackageName,
  mkLivepatchContext,
  mergeChecks,
  nixpkgs,
  root,
  ...
}:

{
  checks = forAllSystems (
    system:
    let
      pkgs = import nixpkgs { inherit system; };
      ownedChecks = pkgs.lib.foldl' mergeChecks ((mkLivepatchContext system).batchChecks pkgs) (
        pkgs.lib.concatMap (owner: pkgs.lib.optional (owner ? checks) (owner.checks { inherit pkgs; })) (
          builtins.attrValues (import (root + "/tests/kernel-specific") { inherit (pkgs) lib; })
        )
      );

    in
    mergeChecks ownedChecks {
      livepatch-discover-selector =
        pkgs.runCommand "livepatch-discover-selector-check"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.coreutils
              pkgs.jq
            ];
          }
          ''
            ${pkgs.bash}/bin/bash ${(root + "/tools/livepatch/tests/discover-selector.sh")} \
              ${(root + "/tools/livepatch/discover.sh")} ${pkgs.bash}/bin/bash > selector.log
            grep -Fx 'livepatch discover selector checks passed' selector.log >/dev/null
            mkdir "$out"
            cp selector.log "$out/result.txt"
          '';

      livepatch-regression = import (root + "/tests/configs/vpsadminos/livepatch-regression-test.nix") {
        inherit pkgs root system;
      };

      livepatch-qualification = import (root + "/os/livepatches/tests/default.nix") {
        inherit
          livepatchCiTools
          livepatchPackageName
          mkLivepatchContext
          nixpkgs
          pkgs
          root
          system
          ;
      };
    }
  );
}
