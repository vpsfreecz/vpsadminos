{
  pkgs,
  plan,
  ciTools,
}:
let
  repo = ../../../../../..;
  inheritedCheck = import ../../1/qualification/check.nix { inherit pkgs plan ciTools; };
  selectedSet = builtins.head plan.sets;
  sequenceRow = builtins.head (
    builtins.filter (
      row: row.scope == "fix" && row.oracleIds == [ "nfsd-sequence-operation-safety" ]
    ) plan.rows
  );
  helper = import ./helpers/nfsd-sequence-operation-safety.nix {
    inherit pkgs plan;
    capture = { };
    oracle = { };
    qualificationSet = selectedSet;
    row = sequenceRow;
  };
  oracleScript = pkgs.writeText "livepatch-nfsd-sequence-oracle.rb" helper.oracleScripts.operation-safety;
  planFile = pkgs.writeText "livepatch-plan-sequence.json" (builtins.toJSON plan);
in
assert builtins.length plan.rows == 24;
inheritedCheck.overrideAttrs (old: {
  buildCommand = old.buildCommand + ''
    ${pkgs.ruby}/bin/ruby -c ${oracleScript}
    ${pkgs.bash}/bin/bash ${repo + /tools/livepatch/tests/hybrid-validator-rows.sh} \
      ${planFile} ${repo} ${oracleScript} ${pkgs.ruby}/bin/ruby \
      > "$out/hybrid-validator-rows.log"
  '';
})
