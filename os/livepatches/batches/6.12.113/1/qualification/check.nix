# Acceptance of this actual batch, independent of other catalog targets.
{
  pkgs,
  plan,
  ciTools,
}:
let
  repo = ../../../../../..;
  qualificationActualPlan = plan;
  qualificationActualSet = builtins.head qualificationActualPlan.sets;
  qualificationActualFixRow = builtins.head (
    builtins.filter (row: row.scope == "fix" && row.platformId == "amd") qualificationActualPlan.rows
  );
  qualificationActualOracle = builtins.head (
    builtins.filter (oracle: oracle.id == "nfs-client-operation-safety") qualificationActualSet.oracles
  );
  qualificationActualIdentity = {
    producer = "/nix/store/00000000000000000000000000000000-synthetic-producer";
    module = "/nix/store/00000000000000000000000000000000-synthetic-producer/synthetic.ko";
    moduleName = "synthetic_livepatch";
    moduleSha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    targetId = "synthetic-target";
    inputDigest = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    manifestSha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
    inspectionSha256 = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
    closureSha256 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
    vermagic = "6.12.113 synthetic";
    sourceRevision = qualificationActualPlan.sourceRevision;
    flakeLockSha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  };
  qualificationActualAudit = {
    deriver = "/nix/store/00000000000000000000000000000000-synthetic-producer.drv";
    requisites = [ "/nix/store/00000000000000000000000000000000-synthetic-producer" ];
    expectedInspectionSha256 = "1111111111111111111111111111111111111111111111111111111111111111";
    frameworkSha256 = "2222222222222222222222222222222222222222222222222222222222222222";
    generatedHeaderSha256 = "3333333333333333333333333333333333333333333333333333333333333333";
    changedObjectsSha256 = "4444444444444444444444444444444444444444444444444444444444444444";
    buildLogSha256 = "5555555555555555555555555555555555555555555555555555555555555555";
    buildLogIdentity = "per-realization-only";
  };
  qualificationActualCapture = {
    schemaVersion = 1;
    sourceRevision = qualificationActualPlan.sourceRevision;
    flakeLockSha256 = qualificationActualIdentity.flakeLockSha256;
    rawBuildLogIdentity = "per-realization-only";
    selectedSets = 1;
    counts = {
      plannedMembers = 1;
      capturedMembers = 1;
    };
    sets = [
      {
        id = qualificationActualSet.id;
        members = [
          {
            release = (builtins.head qualificationActualSet.members).release;
            identity = qualificationActualIdentity;
            audit = qualificationActualAudit;
          }
        ];
      }
    ];
  };
  qualificationActualNfsHelper = import ./helpers/nfs-sysfs-client-lifetime.nix {
    capture = qualificationActualCapture;
    oracle = qualificationActualOracle;
    plan = qualificationActualPlan;
    inherit pkgs;
    qualificationSet = qualificationActualSet;
    row = qualificationActualFixRow;
  };
  qualificationActualAgedRows = builtins.filter (
    row: row.role == "aged-transition"
  ) qualificationActualPlan.rows;
  qualificationActualPlanFile = pkgs.writeText "livepatch-plan-actual.json" (
    builtins.toJSON qualificationActualPlan
  );
  qualificationActualCaptureFile = pkgs.writeText "livepatch-capture-actual.json" (
    builtins.toJSON qualificationActualCapture
  );
  qualificationActualNfsOracleFile = pkgs.writeText "livepatch-nfs-oracle-actual.rb" (
    qualificationActualNfsHelper.oracleScripts.operation-safety
  );
  qualificationNfsValidator = pkgs.writeShellScript "validate-nfs-livepatch-result" ''
    exec ${pkgs.bash}/bin/bash ${./validators/nfs-sysfs-client-lifetime.sh} "$@"
  '';
  genericValidator = pkgs.writeShellScript "validate-generic-livepatch-result" ''
    exec ${pkgs.bash}/bin/bash ${repo + /tools/livepatch/validate-generic-result.sh} "$@"
  '';
in
assert qualificationActualPlan.counts.plannedMembers == 1;
assert qualificationActualPlan.counts.plannedRows == 10;
assert qualificationActualPlan.counts.matrixRows == 10;
assert
  builtins.length (builtins.filter (row: row.scope == "set") qualificationActualPlan.rows) == 8;
assert
  builtins.length (builtins.filter (row: row.scope == "fix") qualificationActualPlan.rows) == 2;
assert
  builtins.attrNames (builtins.head (builtins.head qualificationActualCapture.sets).members) == [
    "audit"
    "identity"
    "release"
  ];
assert builtins.length qualificationActualAgedRows == 2;
assert builtins.all (
  row:
  row.aging == {
    checkpointSeconds = 60;
    developmentDwellSeconds = 300;
    dwellSeconds = 1800;
    evidenceClass = "release";
    releaseDwellSeconds = 1800;
  }
) qualificationActualAgedRows;
pkgs.runCommand "livepatch-qualification-6.12.113.1-check" { nativeBuildInputs = [ ciTools ]; } ''
  actual=${qualificationActualPlanFile}
  jq -e '
    .counts.plannedRows == 10
    and .counts.matrixRows == 10
    and ([.rows[] | select(.role == "aged-transition")] | length) == 2
    and ([.rows[] | select(.role == "aged-transition") | .aging.evidenceClass] | unique) == ["release"]
    and ([.rows[] | select(.role == "aged-transition") | .aging.dwellSeconds] | unique) == [1800]
    and ([.rows[] | select(.role == "aged-transition") | .aging.developmentDwellSeconds] | unique) == [300]
    and ([.rows[] | select(.role == "aged-transition") | .aging.releaseDwellSeconds] | unique) == [1800]
    and ([.rows[] | select(.role == "aged-transition") | .aging.checkpointSeconds] | unique) == [60]
  ' "$actual" >/dev/null

  mkdir "$out"
  ${pkgs.bash}/bin/bash ${./nfs-acceptance.sh} \
    ${qualificationNfsValidator} \
    ${qualificationActualNfsOracleFile} \
    ${qualificationActualPlanFile} \
    ${qualificationActualCaptureFile} \
    ${pkgs.ruby}/bin/ruby \
    ${repo + /tools/livepatch/run-profile.sh} \
    ${genericValidator} \
    ${repo + /tools/livepatch/tests/profile-fixture.sh} \
    ${repo + /tools/livepatch/tests/reverse-fixture.sh} \
    > "$out/nfs-acceptance.log"
  cp ${qualificationActualPlanFile} "$out/plan-actual.json"
  cp ${qualificationActualCaptureFile} "$out/capture-actual.json"
  cp ${qualificationActualNfsOracleFile} "$out/nfs-oracle-actual.rb"
''
