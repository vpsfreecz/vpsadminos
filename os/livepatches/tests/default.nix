{
  livepatchCiTools,
  livepatchPackageName,
  mkLivepatchContext,
  nixpkgs,
  pkgs,
  root,
  system,
}:

let
  lib = pkgs.lib;
  planner = import (root + "/os/livepatches/qualification.nix") { inherit lib; };
  target.kernelVersion = "6.12.113";
  profiles = [
    "set/vendor-aged-transition"
    "set/vendor-busy-transition"
    "set/vendor-failure-recovery"
    "set/vendor-lifecycle"
  ];
  platforms = {
    amd.runnerClass = "amd-livepatch";
    intel.runnerClass = "intel-kvm";
  };
  developmentAging = {
    developmentDwellSeconds = 300;
    releaseDwellSeconds = 1800;
    selectedEvidenceClass = "development-short";
  };
  mkOracle = fixId: oracleId: {
    schemaVersion = 1;
    inherit fixId;
    oracles = [
      {
        id = oracleId;
        scope = "fix";
        role = "fixed-path";
        applicablePlatforms = [
          "amd"
          "intel"
        ];
        timeoutClass = "oracle";
        expectedOutcome = "success";
        testAdapter = "os/livepatches/batches/6.12.113/1/qualification/helpers/${fixId}.nix";
        validator = "os/livepatches/batches/6.12.113/1/qualification/validators/${fixId}.sh";
      }
    ];
  };
  mkEntry =
    ordinal: fixId: oracleId: evidenceClass:
    let
      release = "6.12.113.${toString ordinal}";
    in
    {
      batch = {
        inherit release;
        kernelTarget.kernelVersion = target.kernelVersion;
        payloadRevision = 1;
        unameLevel.releaseOrdinal = ordinal;
        lineage.predecessorBatch =
          if ordinal == 1 then null else { release = "6.12.113.${toString (ordinal - 1)}"; };
        fixes = [ { id = fixId; } ];
        oracleIds = [ oracleId ];
      };
      qualification = {
        schemaVersion = 1;
        inherit release;
        requiredGenericProfiles = profiles;
        inherit platforms;
        profileSettings."set/vendor-aged-transition" = developmentAging // {
          selectedEvidenceClass = evidenceClass;
        };
        oracles = [ (mkOracle fixId oracleId) ];
      };
    };
  rootEntry = mkEntry 1 "fix-a" "oracle-a" "development-short";
  successorEntry = mkEntry 2 "fix-b" "oracle-b" "development-short";
  mkPlan =
    entries:
    planner {
      builder = { };
      catalog = [ ];
      inherit target system;
      normalizedReleases = entries;
      plan = true;
      producerAttrs = builtins.listToAttrs (
        map (entry: {
          name = entry.batch.release;
          value = livepatchPackageName entry.batch.release;
        }) entries
      );
      sourceRevision = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    };
  planOne = mkPlan [ rootEntry ];
  planTwo = mkPlan [
    rootEntry
    successorEntry
  ];
  releasePlan = mkPlan [ (mkEntry 1 "fix-a" "oracle-a" "release") ];
  agedRows = plan: builtins.filter (row: row.role == "aged-transition") plan.rows;

  planOneFile = pkgs.writeText "livepatch-plan-one.json" (builtins.toJSON planOne);
  planTwoFile = pkgs.writeText "livepatch-plan-two.json" (builtins.toJSON planTwo);
  resultVerifier = pkgs.writeShellScript "verify-livepatch-result" ''
    exec ${pkgs.bash}/bin/bash ${(root + "/tools/livepatch/verify.sh")} "$@"
  '';
  stackManagerUnit = import (root + "/os/modules/services/livepatches/tests/default.nix") {
    inherit pkgs;
  };
  coverageReference = {
    schemaVersion = 1;
    sourceRevision = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    flakeLockSha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    kernelVersion = "6.12.113";
    automaticLoad = {
      enable = true;
      loadOnBoot = true;
    };
    targetId = "target-a";
    system = system;
    members = [
      {
        release = "6.12.113.1";
        targetId = "target-a";
        producer = "/nix/store/11111111111111111111111111111111-producer";
        module = "/nix/store/11111111111111111111111111111111-producer/livepatch.ko";
        moduleName = "livepatch_fixture";
      }
    ];
  };
  coverageSet = {
    id = "6.12.113.1";
    kernelVersion = "6.12.113";
    tipRelease = "6.12.113.1";
    members = [ { release = "6.12.113.1"; } ];
  };
  coveragePlan.sets = [ coverageSet ];
  coverageCapture = {
    sourceRevision = coverageReference.sourceRevision;
    flakeLockSha256 = coverageReference.flakeLockSha256;
    sets = [
      {
        id = coverageSet.id;
        members = map (member: {
          inherit (member) release;
          identity = builtins.removeAttrs member [ "release" ];
        }) coverageReference.members;
      }
    ];
  };
  evaluateCoverage =
    event: selectedCapture:
    import (root + "/tools/livepatch/ordinary-coverage.nix") {
      flake.inputs.nixpkgs.lib = lib;
      reference = coverageReference;
      plan = coveragePlan;
      affectedPlan = coveragePlan;
      capture = selectedCapture;
      inherit event;
    };
  mutateCoverageIdentity =
    name: value:
    let
      set = builtins.head coverageCapture.sets;
      member = builtins.head set.members;
    in
    evaluateCoverage "push" (
      coverageCapture
      // {
        sets = [
          (
            set
            // {
              members = [
                (
                  member
                  // {
                    identity = member.identity // builtins.listToAttrs [ { inherit name value; } ];
                  }
                )
              ];
            }
          )
        ];
      }
    );
  changedReleaseCoverage =
    let
      set = builtins.head coverageCapture.sets;
      member = builtins.head set.members;
    in
    evaluateCoverage "push" (
      coverageCapture
      // {
        sets = [ (set // { members = [ (member // { release = "6.12.113.2"; }) ]; }) ];
      }
    );
  changedSourceCoverage = evaluateCoverage "push" (
    coverageCapture // { sourceRevision = "cccccccccccccccccccccccccccccccccccccccc"; }
  );
  changedLockCoverage = evaluateCoverage "push" (
    coverageCapture
    // {
      flakeLockSha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
    }
  );
in
assert planOne.counts.plannedMembers == 1;
assert planOne.counts.matrixRows == 10;
assert planOne.counts.coverageTuples == 2;
assert planTwo.counts.plannedMembers == 2;
assert planTwo.counts.matrixRows == 12;
assert planTwo.counts.coverageTuples == 4;
assert builtins.all (row: row.aging.evidenceClass == "development-short") (agedRows planOne);
assert builtins.all (row: row.aging.evidenceClass == "release") (agedRows releasePlan);
assert
  map (row: builtins.removeAttrs row [ "aging" ]) planOne.rows
  == map (row: builtins.removeAttrs row [ "aging" ]) releasePlan.rows;
assert (evaluateCoverage "push" coverageCapture).workloadMatrix.include == [ ];
assert
  builtins.length (evaluateCoverage "workflow_dispatch" coverageCapture).workloadMatrix.include == 1;
assert builtins.length (mutateCoverageIdentity "targetId" "target-b").workloadMatrix.include == 1;
assert
  builtins.length (mutateCoverageIdentity "producer" "/nix/store/22222222222222222222222222222222-producer")
  .workloadMatrix.include == 1;
assert builtins.length changedReleaseCoverage.workloadMatrix.include == 1;
assert
  builtins.length (mutateCoverageIdentity "module" "/nix/store/11111111111111111111111111111111-producer/other.ko")
  .workloadMatrix.include == 1;
assert
  builtins.length (mutateCoverageIdentity "moduleName" "other_module").workloadMatrix.include == 1;
assert builtins.length changedSourceCoverage.workloadMatrix.include == 1;
assert builtins.length changedLockCoverage.workloadMatrix.include == 1;
pkgs.runCommand "livepatch-qualification-check"
  {
    livepatchCiTools = livepatchCiTools.${system};
    inherit stackManagerUnit;
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.jq
    ];
  }
  ''
    set -euo pipefail

    test -e "$stackManagerUnit"
    jq -e '.selectedSets == 1 and .counts.plannedMembers == 1 and .counts.matrixRows == 10' \
      ${planOneFile} >/dev/null
    jq -e '.selectedSets == 1 and .counts.plannedMembers == 2 and .counts.matrixRows == 12' \
      ${planTwoFile} >/dev/null
    ${pkgs.bash}/bin/bash ${(root + "/tools/livepatch/tests/verify-capture.sh")} \
      ${pkgs.bash}/bin/bash \
      ${resultVerifier} \
      ${(root + "/tools/livepatch/capture.sh")} \
      ${(root + "/tools/livepatch/run-profile.sh")} \
      ${(root + "/tools/livepatch/ci-workspace.sh")} \
      ${(root + "/.github/workflows/livepatch.yml")} \
      > verify-capture.log

    ${pkgs.bash}/bin/bash ${(root + "/tools/livepatch/tests/ci-tool-closure.sh")} \
      ${root} "$livepatchCiTools" > ci-tool-closure.log

    mkdir "$out"
    cp verify-capture.log "$out/verify-capture.log"
    cp ci-tool-closure.log "$out/ci-tool-closure.log"
  ''
