# Reuse inherited NFS acceptance against this release's complete stack.
{
  pkgs,
  plan,
  ciTools,
}:
let
  repo = ../../../../../..;
  inheritedCheck = import ../../1/qualification/check.nix { inherit pkgs plan ciTools; };
  planFile = pkgs.writeText "livepatch-plan-hybrid.json" (builtins.toJSON plan);
in
assert builtins.length plan.rows == 23;
inheritedCheck.overrideAttrs (old: {
  buildCommand = old.buildCommand + ''
    ${pkgs.bash}/bin/bash ${repo + /tools/livepatch/tests/hybrid-validator-rows.sh} \
      ${planFile} ${repo} > "$out/hybrid-validator-rows.log"
  '';
})
