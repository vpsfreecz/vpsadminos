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

  actualPlan = (mkLivepatchContext system).qualification;
  actualCatalog = import (root + "/os/livepatches/batches") { lib = nixpkgs.lib; };
  actualSets = actualPlan.sets;
  actualMembers = builtins.concatLists (map (set: set.members) actualSets);
  actualSetRows = builtins.filter (row: row.scope == "set") actualPlan.rows;
  actualFixRows = builtins.filter (row: row.scope == "fix") actualPlan.rows;
  selectedCatalog =
    set: builtins.filter (unit: unit.batch.kernelVersion == set.kernelVersion) actualCatalog;
  tipUnit = set: lib.last (selectedCatalog set);
  expectedAging =
    set:
    let
      settings = (tipUnit set).qualification.profileSettings."set/vendor-aged-transition";
    in
    {
      checkpointSeconds = 60;
      inherit (settings)
        developmentDwellSeconds
        releaseDwellSeconds
        ;
      dwellSeconds =
        if settings.selectedEvidenceClass == "development-short" then
          settings.developmentDwellSeconds
        else
          settings.releaseDwellSeconds;
      evidenceClass = settings.selectedEvidenceClass;
    };
  actualAgedRows = builtins.filter (row: row.role == "aged-transition") actualPlan.rows;
  expectedOracleMembership = lib.sort builtins.lessThan (
    builtins.concatLists (
      map (
        set:
        builtins.concatLists (
          map (
            oracle: map (platformId: "${set.id}\t${oracle.id}\t${platformId}") oracle.platforms
          ) set.oracles
        )
      ) actualSets
    )
  );
  actualCoverageMembership = lib.sort builtins.lessThan (
    map (item: "${item.setId}\t${item.oracleId}\t${item.platformId}") actualPlan.coverage
  );

  nfsUnits = builtins.filter (
    unit:
    builtins.any (
      manifest:
      manifest.fixId == "nfs-sysfs-client-lifetime"
      && builtins.any (oracle: oracle.id == "nfs-client-operation-safety") manifest.oracles
    ) unit.qualification.oracles
  ) actualCatalog;
  nfsUnit =
    assert builtins.length nfsUnits == 1;
    builtins.head nfsUnits;
  nfsSets = builtins.filter (
    set:
    set.kernelVersion == nfsUnit.batch.kernelVersion
    && builtins.any (
      oracle: oracle.fixId == "nfs-sysfs-client-lifetime" && oracle.id == "nfs-client-operation-safety"
    ) set.oracles
  ) actualSets;
  nfsSet =
    assert builtins.length nfsSets == 1;
    builtins.head nfsSets;
  nfsOracles = builtins.filter (
    oracle: oracle.fixId == "nfs-sysfs-client-lifetime" && oracle.id == "nfs-client-operation-safety"
  ) nfsSet.oracles;
  nfsOracle =
    assert builtins.length nfsOracles == 1;
    builtins.head nfsOracles;
  nfsRows = builtins.filter (
    row:
    row.scope == "fix" && row.setId == nfsSet.id && row.id == nfsOracle.id && row.platformId == "amd"
  ) actualPlan.rows;
  nfsRow =
    assert builtins.length nfsRows == 1;
    builtins.head nfsRows;
  hash = kind: member: builtins.hashString "sha256" "${kind}:${member.release}";
  identity =
    index: member:
    let
      tag = lib.replaceStrings [ "." ] [ "_" ] member.release;
      storeKey = lib.fixedWidthNumber 32 (index + 1);
      producer = "/nix/store/${storeKey}-qualification-adapter-${tag}";
    in
    {
      inherit producer;
      module = "${producer}/lib/modules/${nfsSet.kernelVersion}/extra/livepatch_${tag}.ko";
      moduleName = "livepatch_${tag}";
      moduleSha256 = hash "module" member;
      manifestSha256 = hash "manifest" member;
      inspectionSha256 = hash "inspection" member;
      closureSha256 = hash "closure" member;
    };
  captureMembers = lib.imap0 (index: member: {
    inherit (member) release;
    identity = identity index member;
  }) nfsSet.members;
  compactCapture = {
    schemaVersion = 1;
    sourceRevision = actualPlan.sourceRevision;
    sets = [
      {
        id = nfsSet.id;
        members = captureMembers;
      }
    ];
  };
  helperPath = root + "/${nfsOracle.testAdapter}";
  fullHelper = import helperPath {
    capture = compactCapture;
    oracle = nfsOracle;
    plan = actualPlan;
    inherit pkgs;
    qualificationSet = nfsSet;
    row = nfsRow;
  };
  compatibilityMember = builtins.head nfsSet.members;
  compatibilitySet = nfsSet // {
    id = compatibilityMember.release;
    tipRelease = compatibilityMember.release;
    members = [ compatibilityMember ];
  };
  compatibilityPlan = actualPlan // {
    selectedSets = 1;
    sets = [ compatibilitySet ];
  };
  compatibilityCapture = compactCapture // {
    sets = [
      {
        id = compatibilitySet.id;
        members = [ (builtins.head captureMembers) ];
      }
    ];
  };
  compatibilityRow = nfsRow // {
    setId = compatibilitySet.id;
    rowId = lib.replaceStrings [ nfsSet.id ] [ compatibilitySet.id ] nfsRow.rowId;
  };
  compatibilityHelper = import helperPath {
    capture = compatibilityCapture;
    oracle = nfsOracle;
    plan = compatibilityPlan;
    inherit pkgs;
    qualificationSet = compatibilitySet;
    row = compatibilityRow;
  };

  planOneFile = pkgs.writeText "livepatch-plan-one.json" (builtins.toJSON planOne);
  planTwoFile = pkgs.writeText "livepatch-plan-two.json" (builtins.toJSON planTwo);
  actualPlanFile = pkgs.writeText "livepatch-plan-actual.json" (builtins.toJSON actualPlan);
  fullNfsFile = pkgs.writeText "livepatch-nfs-oracle-full.rb" fullHelper.oracleScripts.operation-safety;
  compatibilityNfsFile = pkgs.writeText "livepatch-nfs-oracle-one.rb" (
    compatibilityHelper.oracleScripts.operation-safety
  );
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
assert actualPlan.schemaVersion == 1;
assert actualSets != [ ];
assert actualPlan.counts.catalogReleases == builtins.length actualCatalog;
assert actualPlan.counts.plannedMembers == builtins.length actualMembers;
assert actualPlan.counts.plannedRows == builtins.length actualPlan.rows;
assert actualPlan.counts.matrixRows == builtins.length actualPlan.matrix.include;
assert
  actualPlan.counts.plannedRows == builtins.length actualSetRows + builtins.length actualFixRows;
assert expectedOracleMembership == actualCoverageMembership;
assert builtins.all (
  set:
  map (unit: unit.batch.release) (selectedCatalog set) == map (member: member.release) set.members
) actualSets;
assert builtins.all (
  row: row.aging == expectedAging (lib.findFirst (set: set.id == row.setId) null actualSets)
) actualAgedRows;
assert builtins.length captureMembers == builtins.length nfsSet.members;
assert
  builtins.attrNames (builtins.head captureMembers).identity == [
    "closureSha256"
    "inspectionSha256"
    "manifestSha256"
    "module"
    "moduleName"
    "moduleSha256"
    "producer"
  ];
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
    jq -e '.counts.catalogReleases == (.releases | length)' ${actualPlanFile} >/dev/null

    for release in ${
      lib.concatStringsSep " " (map lib.escapeShellArg (map (member: member.release) nfsSet.members))
    }; do
      grep -F "$release" ${fullNfsFile} >/dev/null
    done
    grep -F ${lib.escapeShellArg compatibilityMember.release} ${compatibilityNfsFile} >/dev/null
    if grep -F ${lib.escapeShellArg nfsSet.tipRelease} ${compatibilityNfsFile} >/dev/null \
      && test ${lib.escapeShellArg compatibilityMember.release} != ${lib.escapeShellArg nfsSet.tipRelease}; then
      echo 'one-member NFS render retained the full-stack tip' >&2
      exit 1
    fi

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
    cp ${actualPlanFile} "$out/plan-actual.json"
    cp ${fullNfsFile} "$out/nfs-oracle-full.rb"
    cp ${compatibilityNfsFile} "$out/nfs-oracle-one.rb"
    cp verify-capture.log "$out/verify-capture.log"
    cp ci-tool-closure.log "$out/ci-tool-closure.log"
  ''
