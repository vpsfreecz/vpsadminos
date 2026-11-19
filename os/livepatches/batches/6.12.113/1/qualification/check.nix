# Acceptance of this actual batch, independent of other catalog targets.
{
  pkgs,
  plan,
  ciTools,
}:
let
  repo = ../../../../../..;
  qualificationActualPlan = plan;
  qualificationActualSets = qualificationActualPlan.sets;
  qualificationActualCatalog = builtins.filter (
    unit: builtins.elem unit.batch.release (map (release: release.release) plan.releases)
  ) (import ../../.. { lib = pkgs.lib; });
  qualificationActualSelectedCatalogForSet =
    set:
    builtins.filter (unit: unit.batch.kernelVersion == set.kernelVersion) qualificationActualCatalog;
  qualificationActualTipForSet = set: pkgs.lib.last (qualificationActualSelectedCatalogForSet set);
  qualificationActualCatalogReleases = map (unit: unit.batch.release) qualificationActualCatalog;
  qualificationActualSortedCatalogReleases = builtins.sort builtins.lessThan qualificationActualCatalogReleases;
  qualificationActualPlannedReleases = map (
    release: release.release
  ) qualificationActualPlan.releases;
  qualificationActualSortedPlannedReleases = builtins.sort builtins.lessThan qualificationActualPlannedReleases;
  qualificationActualMemberReleases = builtins.concatLists (
    map (set: map (member: member.release) set.members) qualificationActualSets
  );
  qualificationActualSetRows = builtins.filter (row: row.scope == "set") qualificationActualPlan.rows;
  qualificationActualFixRows = builtins.filter (row: row.scope == "fix") qualificationActualPlan.rows;
  qualificationActualExpectedAgingForSet =
    set:
    let
      tip = qualificationActualTipForSet set;
      settings = tip.qualification.profileSettings."set/vendor-aged-transition";
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
  qualificationActualExpectedAgingBySet = builtins.listToAttrs (
    map (set: {
      name = set.id;
      value = qualificationActualExpectedAgingForSet set;
    }) qualificationActualSets
  );
  qualificationActualExpectedOraclePlatforms = builtins.concatLists (
    map (
      set:
      builtins.concatLists (
        map (
          oracle:
          map (platformId: {
            inherit (oracle) fixId;
            oracleId = oracle.id;
            inherit platformId;
            setId = set.id;
          }) oracle.platforms
        ) set.oracles
      )
    ) qualificationActualSets
  );
  qualificationActualExpectedFixMembership = builtins.sort builtins.lessThan (
    map (
      item: "${item.setId}\t${item.fixId}\t${item.oracleId}\t${item.platformId}"
    ) qualificationActualExpectedOraclePlatforms
  );
  qualificationActualFixMembership = builtins.sort builtins.lessThan (
    map (row: "${row.setId}\t${row.fixId}\t${row.id}\t${row.platformId}") qualificationActualFixRows
  );
  qualificationActualExpectedCoverageMembership = builtins.sort builtins.lessThan (
    map (
      item: "${item.setId}\t${item.oracleId}\t${item.platformId}"
    ) qualificationActualExpectedOraclePlatforms
  );
  qualificationActualCoverageMembership = builtins.sort builtins.lessThan (
    map (item: "${item.setId}\t${item.oracleId}\t${item.platformId}") qualificationActualPlan.coverage
  );
  qualificationActualNfsCatalogUnits = builtins.filter (
    unit:
    builtins.any (
      manifest:
      manifest.fixId == "nfs-sysfs-client-lifetime"
      && builtins.any (oracle: oracle.id == "nfs-client-operation-safety") manifest.oracles
    ) unit.qualification.oracles
  ) qualificationActualCatalog;
  qualificationActualNfsCatalogUnit =
    assert builtins.length qualificationActualNfsCatalogUnits == 1;
    builtins.head qualificationActualNfsCatalogUnits;
  qualificationActualNfsSets = builtins.filter (
    set:
    set.kernelVersion == qualificationActualNfsCatalogUnit.batch.kernelVersion
    && builtins.any (
      oracle: oracle.fixId == "nfs-sysfs-client-lifetime" && oracle.id == "nfs-client-operation-safety"
    ) set.oracles
  ) qualificationActualSets;
  qualificationActualNfsSet =
    assert builtins.length qualificationActualNfsSets == 1;
    builtins.head qualificationActualNfsSets;
  qualificationActualNfsSetRows = builtins.filter (
    row: row.scope == "set" && row.setId == qualificationActualNfsSet.id
  ) qualificationActualPlan.rows;
  qualificationActualNfsRows = builtins.filter (
    row:
    row.scope == "fix"
    && row.setId == qualificationActualNfsSet.id
    && row.fixId == "nfs-sysfs-client-lifetime"
    && row.id == "nfs-client-operation-safety"
    && row.oracleIds == [ "nfs-client-operation-safety" ]
  ) qualificationActualPlan.rows;
  qualificationActualNfsFixRows = builtins.filter (
    row: row.platformId == "amd"
  ) qualificationActualNfsRows;
  qualificationActualFixRow =
    assert builtins.length qualificationActualNfsFixRows == 1;
    builtins.head qualificationActualNfsFixRows;
  qualificationActualNfsOracles = builtins.filter (
    oracle: oracle.fixId == "nfs-sysfs-client-lifetime" && oracle.id == "nfs-client-operation-safety"
  ) qualificationActualNfsSet.oracles;
  qualificationActualOracle =
    assert builtins.length qualificationActualNfsOracles == 1;
    builtins.head qualificationActualNfsOracles;
  qualificationActualFlakeLockSha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  qualificationActualSyntheticHash =
    kind: set: member:
    builtins.hashString "sha256" "${kind}:${set.kernelVersion}:${member.release}";
  qualificationActualIdentity =
    setIndex: memberIndex: set: member:
    let
      releaseTag = pkgs.lib.replaceStrings [ "." ] [ "_" ] member.release;
      syntheticHash = kind: qualificationActualSyntheticHash kind set member;
      producerKey = "${pkgs.lib.fixedWidthNumber 16 (setIndex + 1)}${
        pkgs.lib.fixedWidthNumber 16 (memberIndex + 1)
      }";
      producer = "/nix/store/${producerKey}-synthetic-producer-${releaseTag}";
    in
    {
      inherit producer;
      module = "${producer}/synthetic-${releaseTag}.ko";
      moduleName = "synthetic_livepatch_${toString (setIndex + 1)}_${toString member.releaseOrdinal}";
      moduleSha256 = syntheticHash "module";
      targetId = "synthetic-target-${set.kernelVersion}";
      inputDigest = syntheticHash "input";
      manifestSha256 = syntheticHash "manifest";
      inspectionSha256 = syntheticHash "inspection";
      closureSha256 = syntheticHash "closure";
      vermagic = "${set.kernelVersion} synthetic";
      sourceRevision = qualificationActualPlan.sourceRevision;
      flakeLockSha256 = qualificationActualFlakeLockSha256;
    };
  qualificationActualAudit =
    set: member: identity:
    let
      syntheticHash = kind: qualificationActualSyntheticHash kind set member;
    in
    {
      deriver = "${identity.producer}.drv";
      requisites = [ identity.producer ];
      expectedInspectionSha256 = syntheticHash "expected-inspection";
      frameworkSha256 = syntheticHash "framework";
      generatedHeaderSha256 = syntheticHash "generated-header";
      changedObjectsSha256 = syntheticHash "changed-objects";
      buildLogSha256 = syntheticHash "build-log";
      buildLogIdentity = "per-realization-only";
    };
  qualificationActualCaptureSets = pkgs.lib.imap0 (setIndex: set: {
    id = set.id;
    members = pkgs.lib.imap0 (
      memberIndex: member:
      let
        identity = qualificationActualIdentity setIndex memberIndex set member;
      in
      {
        inherit (member) release;
        inherit identity;
        audit = qualificationActualAudit set member identity;
      }
    ) set.members;
  }) qualificationActualSets;
  qualificationActualCapturedMembers = builtins.concatLists (
    map (set: set.members) qualificationActualCaptureSets
  );
  qualificationActualCapture = {
    schemaVersion = 1;
    sourceRevision = qualificationActualPlan.sourceRevision;
    flakeLockSha256 = qualificationActualFlakeLockSha256;
    rawBuildLogIdentity = "per-realization-only";
    selectedSets = builtins.length qualificationActualCaptureSets;
    counts = {
      plannedMembers = builtins.length qualificationActualCapturedMembers;
      capturedMembers = builtins.length qualificationActualCapturedMembers;
    };
    sets = qualificationActualCaptureSets;
  };
  qualificationActualNfsCapturedSets = builtins.filter (
    set: set.id == qualificationActualNfsSet.id
  ) qualificationActualCaptureSets;
  qualificationActualNfsCapturedSet =
    assert builtins.length qualificationActualNfsCapturedSets == 1;
    builtins.head qualificationActualNfsCapturedSets;
  qualificationNfsCompatibilitySetId = (builtins.head qualificationActualNfsSet.members).release;
  qualificationNfsCompatibilityReleases = builtins.filter (
    release: release.release == qualificationNfsCompatibilitySetId
  ) qualificationActualPlan.releases;
  qualificationNfsCompatibilityRelease =
    assert builtins.length qualificationNfsCompatibilityReleases == 1;
    builtins.head qualificationNfsCompatibilityReleases;
  qualificationNfsCompatibilityAging = {
    checkpointSeconds = 60;
    developmentDwellSeconds = 300;
    dwellSeconds = 1800;
    evidenceClass = "release";
    releaseDwellSeconds = 1800;
  };
  rebaseQualificationNfsCompatibilityRow =
    row:
    row
    // {
      setId = qualificationNfsCompatibilitySetId;
      rowId =
        pkgs.lib.replaceStrings
          [ "${qualificationActualNfsSet.id}--" ]
          [
            "${qualificationNfsCompatibilitySetId}--"
          ]
          row.rowId;
    }
    // pkgs.lib.optionalAttrs ((row.role or null) == "aged-transition") {
      aging = qualificationNfsCompatibilityAging;
    };
  qualificationNfsCompatibilityRows = map rebaseQualificationNfsCompatibilityRow (
    qualificationActualNfsSetRows ++ qualificationActualNfsRows
  );
  qualificationNfsCompatibilityCoverage = map rebaseQualificationNfsCompatibilityRow (
    builtins.filter (
      entry:
      entry.setId == qualificationActualNfsSet.id && entry.oracleId == "nfs-client-operation-safety"
    ) qualificationActualPlan.coverage
  );
  qualificationNfsCompatibilitySet = qualificationActualNfsSet // {
    id = qualificationNfsCompatibilitySetId;
    tipRelease = qualificationNfsCompatibilitySetId;
    members = [ (builtins.head qualificationActualNfsSet.members) ];
    oracleIds = [ "nfs-client-operation-safety" ];
    oracles = [ qualificationActualOracle ];
  };
  qualificationNfsCompatibilityPlan = qualificationActualPlan // {
    selectedSets = 1;
    releases = [ qualificationNfsCompatibilityRelease ];
    sets = [ qualificationNfsCompatibilitySet ];
    rows = qualificationNfsCompatibilityRows;
    coverage = qualificationNfsCompatibilityCoverage;
    matrix.include = compactQualificationRows qualificationNfsCompatibilityRows;
    counts = {
      catalogReleases = 1;
      normalizedReleases = 1;
      plannedMembers = builtins.length qualificationNfsCompatibilitySet.members;
      requiredProfilePlatformTuples = builtins.length qualificationActualNfsSetRows;
      activeOracles = builtins.length qualificationNfsCompatibilitySet.oracles;
      coverageTuples = builtins.length qualificationNfsCompatibilityCoverage;
      plannedRows = builtins.length qualificationNfsCompatibilityRows;
      matrixRows = builtins.length qualificationNfsCompatibilityRows;
    };
  };
  qualificationNfsCompatibilityCapture = qualificationActualCapture // {
    selectedSets = 1;
    counts = {
      plannedMembers = 1;
      capturedMembers = 1;
    };
    sets = [
      {
        id = qualificationNfsCompatibilitySetId;
        members = [ (builtins.head qualificationActualNfsCapturedSet.members) ];
      }
    ];
  };
  qualificationNfsCompatibilityFixRow = builtins.head (
    builtins.filter (
      row: row.scope == "fix" && row.platformId == "amd"
    ) qualificationNfsCompatibilityRows
  );
  qualificationActualNfsHelper = import ./helpers/nfs-sysfs-client-lifetime.nix {
    capture = qualificationActualCapture;
    oracle = qualificationActualOracle;
    plan = qualificationActualPlan;
    inherit pkgs;
    qualificationSet = qualificationActualNfsSet;
    row = qualificationActualFixRow;
  };
  qualificationNfsCompatibilityHelper = import ./helpers/nfs-sysfs-client-lifetime.nix {
    capture = qualificationNfsCompatibilityCapture;
    oracle = qualificationActualOracle;
    plan = qualificationNfsCompatibilityPlan;
    inherit pkgs;
    qualificationSet = qualificationNfsCompatibilitySet;
    row = qualificationNfsCompatibilityFixRow;
  };
  compactQualificationRows =
    rows:
    map (row: {
      inherit (row)
        expectedOutcome
        profileId
        rowId
        runnerClass
        setId
        timeoutClass
        ;
    }) rows;
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
  qualificationActualExpectedAgingFile = pkgs.writeText "livepatch-aging-actual.json" (
    builtins.toJSON qualificationActualExpectedAgingBySet
  );
  qualificationNfsCompatibilityPlanFile = pkgs.writeText "livepatch-plan-nfs-compatibility.json" (
    builtins.toJSON qualificationNfsCompatibilityPlan
  );
  qualificationNfsCompatibilityCaptureFile = pkgs.writeText "livepatch-capture-nfs-compatibility.json" (
    builtins.toJSON qualificationNfsCompatibilityCapture
  );
  qualificationNfsCompatibilityOracleFile = pkgs.writeText "livepatch-nfs-oracle-compatibility.rb" (
    qualificationNfsCompatibilityHelper.oracleScripts.operation-safety
  );
  qualificationNfsValidator = pkgs.writeShellScript "validate-nfs-livepatch-result" ''
    exec ${pkgs.bash}/bin/bash ${./validators/nfs-sysfs-client-lifetime.sh} "$@"
  '';
  genericValidator = pkgs.writeShellScript "validate-generic-livepatch-result" ''
    exec ${pkgs.bash}/bin/bash ${repo + /tools/livepatch/validate-generic-result.sh} "$@"
  '';
in
assert qualificationActualPlan.schemaVersion == 1;
assert qualificationActualPlan.selectedSets == builtins.length qualificationActualSets;
assert qualificationActualSets != [ ];
assert qualificationActualPlan.counts.catalogReleases == builtins.length qualificationActualCatalog;
assert qualificationActualSortedCatalogReleases == qualificationActualSortedPlannedReleases;
assert qualificationActualPlannedReleases == qualificationActualMemberReleases;
assert qualificationActualMemberReleases != [ ];
assert builtins.all (
  set:
  let
    selectedReleases = map (unit: unit.batch.release) (qualificationActualSelectedCatalogForSet set);
    memberReleases = map (member: member.release) set.members;
  in
  selectedReleases != [ ]
  && selectedReleases == memberReleases
  && set.id == set.tipRelease
  && set.tipRelease == pkgs.lib.last memberReleases
  && builtins.all (member: member.kernelVersion == set.kernelVersion) set.members
) qualificationActualSets;
assert
  qualificationActualPlan.counts.normalizedReleases
  == builtins.length qualificationActualPlan.releases;
assert
  qualificationActualPlan.counts.plannedMembers == builtins.length qualificationActualMemberReleases;
assert
  qualificationActualPlan.counts.activeOracles
  == builtins.length (builtins.concatLists (map (set: set.oracleIds) qualificationActualSets));
assert
  qualificationActualPlan.counts.activeOracles
  == builtins.length (builtins.concatLists (map (set: set.oracles) qualificationActualSets));
assert qualificationActualExpectedFixMembership == qualificationActualFixMembership;
assert qualificationActualExpectedCoverageMembership == qualificationActualCoverageMembership;
assert
  qualificationActualPlan.counts.coverageTuples == builtins.length qualificationActualPlan.coverage;
assert
  qualificationActualPlan.counts.coverageTuples
  == builtins.length qualificationActualExpectedOraclePlatforms;
assert
  qualificationActualPlan.counts.requiredProfilePlatformTuples
  == builtins.length qualificationActualSetRows;
assert qualificationActualPlan.counts.plannedRows == builtins.length qualificationActualPlan.rows;
assert
  qualificationActualPlan.counts.matrixRows == builtins.length qualificationActualPlan.matrix.include;
assert
  qualificationActualPlan.counts.plannedRows
  == builtins.length qualificationActualSetRows + builtins.length qualificationActualFixRows;
assert
  qualificationActualPlan.matrix.include == compactQualificationRows qualificationActualPlan.rows;
assert qualificationActualCapture.selectedSets == qualificationActualPlan.selectedSets;
assert builtins.length qualificationActualCaptureSets == builtins.length qualificationActualSets;
assert
  map (set: set.id) qualificationActualCaptureSets == map (set: set.id) qualificationActualSets;
assert
  qualificationActualCapture.counts.plannedMembers
  == builtins.length qualificationActualMemberReleases;
assert
  qualificationActualCapture.counts.capturedMembers
  == builtins.length qualificationActualCapturedMembers;
assert
  map (member: member.release) qualificationActualCapturedMembers
  == qualificationActualMemberReleases;
assert builtins.all (
  member:
  builtins.attrNames member == [
    "audit"
    "identity"
    "release"
  ]
) qualificationActualCapturedMembers;
assert builtins.all
  (
    field:
    builtins.length (
      pkgs.lib.unique (map (member: member.identity.${field}) qualificationActualCapturedMembers)
    ) == builtins.length qualificationActualCapturedMembers
  )
  [
    "producer"
    "module"
    "moduleName"
    "moduleSha256"
    "inputDigest"
  ];
assert builtins.all (
  captureSet:
  let
    planSet = builtins.head (builtins.filter (set: set.id == captureSet.id) qualificationActualSets);
  in
  builtins.all (
    member:
    member.identity.sourceRevision == qualificationActualPlan.sourceRevision
    && member.identity.flakeLockSha256 == qualificationActualCapture.flakeLockSha256
    && member.identity.targetId == "synthetic-target-${planSet.kernelVersion}"
    && member.identity.vermagic == "${planSet.kernelVersion} synthetic"
    && member.audit.deriver == "${member.identity.producer}.drv"
    && member.audit.requisites == [ member.identity.producer ]
  ) captureSet.members
) qualificationActualCaptureSets;
assert
  builtins.length qualificationActualAgedRows == builtins.length (
    builtins.concatLists (
      map (
        set: builtins.attrNames (qualificationActualTipForSet set).qualification.platforms
      ) qualificationActualSets
    )
  );
assert builtins.all (
  row: row.aging == qualificationActualExpectedAgingBySet.${row.setId}
) qualificationActualAgedRows;
pkgs.runCommand "livepatch-qualification-6.12.113.1-check" { nativeBuildInputs = [ ciTools ]; } ''
  actual=${qualificationActualPlanFile}
  jq -e --slurpfile expectedAging ${qualificationActualExpectedAgingFile} '
    . as $plan
    | [$plan.rows[] | select(.scope == "set")] as $setRows
    | [$plan.rows[] | select(.scope == "fix")] as $fixRows
    | [
        $plan.sets[] as $set
        | $set.oracles[] as $oracle
        | $oracle.platforms[] as $platformId
        | {setId: $set.id, fixId: $oracle.fixId, oracleId: $oracle.id, $platformId}
      ] as $expectedFixMembership
    | .schemaVersion == 1
    and .selectedSets == ($plan.sets | length)
    and (.sets | length) > 0
    and .counts.catalogReleases == ($plan.releases | length)
    and .counts.normalizedReleases == ($plan.releases | length)
    and .counts.plannedMembers == ([$plan.sets[].members[]] | length)
    and .counts.requiredProfilePlatformTuples == ($setRows | length)
    and .counts.activeOracles == ([$plan.sets[].oracleIds[]] | length)
    and .counts.activeOracles == ([$plan.sets[].oracles[]] | length)
    and .counts.coverageTuples == ($plan.coverage | length)
    and .counts.coverageTuples == ($expectedFixMembership | length)
    and .counts.plannedRows == ($plan.rows | length)
    and .counts.plannedRows == (($setRows | length) + ($fixRows | length))
    and .counts.matrixRows == ($plan.matrix.include | length)
    and .counts.plannedRows == .counts.matrixRows
    and ([$plan.releases[].release]) == ([$plan.sets[].members[].release])
    and ([$plan.sets[] as $set
      | ($set.members | length) > 0
        and $set.id == $set.tipRelease
        and $set.tipRelease == $set.members[-1].release
        and ([range(0; ($set.members | length)) as $index
          | $set.members[$index].kernelVersion == $set.kernelVersion
            and $set.members[$index].releaseOrdinal == ($index + 1)
            and $set.members[$index].predecessorRelease
              == (if $index == 0 then null else $set.members[$index - 1].release end)
        ] | all)
    ] | all)
    and ([$plan.sets[] as $set
      | ([$setRows[] | select(.setId == $set.id) | .role] | unique | sort)
        == ["aged-transition", "busy-transition", "failure-recovery", "lifecycle"]
    ] | all)
    and ($setRows | all(
      .oracleIds == []
      and .oracleShard == "none"
      and .validator == "builtin/generic-livepatch-safety-v1"
    ))
    and ($fixRows | map({setId, fixId, oracleId: .id, platformId})
      | sort_by([.setId, .fixId, .oracleId, .platformId]))
      == ($expectedFixMembership | sort_by([.setId, .fixId, .oracleId, .platformId]))
    and ($fixRows | all(. as $row | $row.oracleIds == [$row.id]))
    and ($plan.coverage | sort_by(.rowId)) == ($fixRows | map({
      oracleId: .id,
      platformId,
      profileId,
      rowId,
      setId
    }) | sort_by(.rowId))
    and $plan.matrix.include == ($plan.rows | map({
      expectedOutcome,
      profileId,
      rowId,
      runnerClass,
      setId,
      timeoutClass
    }))
    and ([$plan.sets[] as $set
      | ([$setRows[] | select(.setId == $set.id and .role == "aged-transition")] | length)
        == ([$setRows[] | select(.setId == $set.id) | .platform.id] | unique | length)
    ] | all)
    and ([$plan.rows[] | select(.role == "aged-transition")]
      | all(. as $row | $row.aging == $expectedAging[0][$row.setId]))
    and ($expectedAging[0] | keys | sort) == ([$plan.sets[].id] | sort)
    and ($expectedAging[0] | to_entries | map(.value) | all(
      (keys | sort) == [
        "checkpointSeconds", "developmentDwellSeconds", "dwellSeconds",
        "evidenceClass", "releaseDwellSeconds"
      ]
      and (.checkpointSeconds | type == "number" and floor == . and . > 0)
      and (.developmentDwellSeconds | type == "number" and floor == . and . > 0)
      and (.releaseDwellSeconds | type == "number" and floor == . and . > 0)
      and .developmentDwellSeconds < .releaseDwellSeconds
      and (.evidenceClass == "development-short" or .evidenceClass == "release")
      and .dwellSeconds == (
        if .evidenceClass == "development-short" then
          .developmentDwellSeconds
        else
          .releaseDwellSeconds
        end
      )
    ))
  ' "$actual" >/dev/null

  for release in ${
    pkgs.lib.concatStringsSep " " (
      map pkgs.lib.escapeShellArg (map (member: member.release) qualificationActualNfsSet.members)
    )
  }; do
    grep -F "$release" ${qualificationActualNfsOracleFile} >/dev/null
  done
  grep -F ${pkgs.lib.escapeShellArg qualificationNfsCompatibilitySetId} ${qualificationNfsCompatibilityOracleFile} >/dev/null
  if grep -F ${pkgs.lib.escapeShellArg qualificationActualNfsSet.tipRelease} ${qualificationNfsCompatibilityOracleFile} >/dev/null \
    && test ${pkgs.lib.escapeShellArg qualificationNfsCompatibilitySetId} != ${pkgs.lib.escapeShellArg qualificationActualNfsSet.tipRelease}; then
    echo 'one-member NFS render retained the full-stack tip' >&2
    exit 1
  fi

  mkdir "$out"
  ${pkgs.bash}/bin/bash ${./nfs-acceptance.sh} \
    ${qualificationNfsValidator} \
    ${qualificationNfsCompatibilityOracleFile} \
    ${qualificationNfsCompatibilityPlanFile} \
    ${qualificationNfsCompatibilityCaptureFile} \
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
