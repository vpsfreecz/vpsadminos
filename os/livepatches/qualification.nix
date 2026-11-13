{ lib }:

let
  inherit (lib)
    all
    attrNames
    concatMap
    concatStringsSep
    filter
    findFirst
    foldl'
    genList
    length
    optionalAttrs
    replaceStrings
    sort
    unique
    ;

  livepatchLib = import ./lib.nix { inherit lib; };

  fail = context: message: throw "livepatch qualification ${context}: ${message}";
  require =
    context: condition: message:
    if condition then true else fail context message;
  checked = checks: value: builtins.deepSeq checks value;
  isString = value: builtins.isString value && value != "";
  stableId =
    value: isString value && builtins.match "[a-z0-9]([a-z0-9._:/-]*[a-z0-9])?" value != null;
  uniqueList = values: length (unique values) == length values;
  sorted = sort builtins.lessThan;
  rowComponent = value: replaceStrings [ "/" ":" "." ] [ "-" "-" "-" ] value;

  onlyAttrs =
    context: allowed: value:
    let
      unexpected = filter (name: !(builtins.elem name allowed)) (attrNames value);
    in
    require context (unexpected == [ ]) "unexpected attributes: ${concatStringsSep ", " unexpected}";

  genericProfiles = {
    "set/vendor-lifecycle" = {
      role = "lifecycle";
      scope = "set";
      testAdapter = "kernel/livepatch-set";
      template = "kernel/livepatch-set";
      timeoutClass = "lifecycle";
      expectedOutcome = "success";
      validator = "builtin/generic-livepatch-safety-v1";
    };
    "set/vendor-busy-transition" = {
      role = "busy-transition";
      scope = "set";
      testAdapter = "kernel/livepatch-set";
      template = "kernel/livepatch-set";
      timeoutClass = "transition";
      expectedOutcome = "success";
      validator = "builtin/generic-livepatch-safety-v1";
    };
    "set/vendor-failure-recovery" = {
      role = "failure-recovery";
      scope = "set";
      testAdapter = "kernel/livepatch-set";
      template = "kernel/livepatch-set";
      timeoutClass = "recovery";
      expectedOutcome = "success";
      validator = "builtin/generic-livepatch-safety-v1";
    };
  };
  requiredProfileIds = attrNames genericProfiles;
  requiredPlatformIds = [
    "amd"
    "intel"
  ];
  requiredPlatformRunners = {
    amd = "amd-livepatch";
    intel = "intel-kvm";
  };

  normalizePlatform =
    context: id: platform:
    checked
      [
        (require context (builtins.isAttrs platform) "platform must be an attribute set")
        (onlyAttrs context [
          "runnerClass"
          "unsupportedReason"
        ] platform)
        (require context (isString (platform.runnerClass or "")) "runnerClass must be non-empty")
        (require context (
          builtins.hasAttr id requiredPlatformRunners && platform.runnerClass == requiredPlatformRunners.${id}
        ) "runnerClass does not match the platform")
        (require context (
          !(platform ? unsupportedReason) || isString platform.unsupportedReason
        ) "unsupportedReason must be non-empty when present")
      ]
      (
        {
          inherit id;
          inherit (platform) runnerClass;
          supported = !(platform ? unsupportedReason);
        }
        // optionalAttrs (platform ? unsupportedReason) {
          inherit (platform) unsupportedReason;
        }
      );

  normalizeOracle =
    context: fixId: oracle:
    let
      platforms = sorted (oracle.applicablePlatforms or [ ]);
    in
    checked
      [
        (require context (builtins.isAttrs oracle) "oracle must be an attribute set")
        (onlyAttrs context [
          "applicablePlatforms"
          "expectedOutcome"
          "id"
          "role"
          "scope"
          "testAdapter"
          "timeoutClass"
          "validator"
        ] oracle)
        (require context (stableId (oracle.id or "")) "id is invalid")
        (require context ((oracle.scope or null) == "fix") "scope must be fix")
        (require context (isString (oracle.role or "")) "role must be non-empty")
        (require context (
          builtins.isList platforms && platforms != [ ]
        ) "applicablePlatforms must be a non-empty list")
        (require context (all (
          platform: builtins.elem platform requiredPlatformIds
        ) platforms) "applicablePlatforms contains an unknown platform")
        (require context (uniqueList platforms) "applicablePlatforms must be unique")
        (require context (isString (oracle.timeoutClass or "")) "timeoutClass must be non-empty")
        (require context (isString (oracle.expectedOutcome or "")) "expectedOutcome must be non-empty")
        (require context (
          builtins.match "os/livepatches/batches/[0-9.]+/qualification/helpers/[a-z0-9][a-z0-9._/-]*\\.nix" (
            oracle.testAdapter or ""
          ) != null
          && builtins.match ".*(/\\.\\./|/\\.\\.$).*" oracle.testAdapter == null
        ) "testAdapter must name a fix-local qualification helper")
        (require context (
          builtins.match "os/livepatches/batches/[0-9.]+/qualification/validators/[a-z0-9][a-z0-9._/-]*\\.sh"
            (oracle.validator or "") != null
          && builtins.match ".*(/\\.\\./|/\\.\\.$).*" oracle.validator == null
        ) "validator must name a fix-local qualification validator")
      ]
      {
        inherit fixId platforms;
        inherit (oracle)
          expectedOutcome
          id
          role
          scope
          testAdapter
          timeoutClass
          validator
          ;
      };
in
{
  builder,
  catalog ? import ./batches/default.nix { inherit lib; },
  target,
  normalizedReleases ? null,
  plan ? false,
  producerAttrs ? { },
  sourceRevision ? null,
  system ? "x86_64-linux",
}:
let
  releases =
    if normalizedReleases == null then
      livepatchLib.normalizeCatalog {
        inherit builder catalog target;
      }
    else
      normalizedReleases;

  planned =
    if releases == [ ] then
      {
        schemaVersion = 1;
        dormant = true;
        selectedSets = 0;
        inherit releases;
        sets = [ ];
        rows = [ ];
        coverage = [ ];
        matrix.include = [ ];
        counts = {
          catalogReleases = 0;
          normalizedReleases = 0;
          plannedMembers = 0;
          requiredProfilePlatformTuples = 0;
          activeOracles = 0;
          coverageTuples = 0;
          plannedRows = 0;
          matrixRows = 0;
        };
        inherit sourceRevision system;
      }
    else
      let
        context = "set ${target.kernelVersion}";
        releaseIds = map (entry: entry.batch.release) releases;
        ordinals = map (entry: entry.batch.unameLevel.releaseOrdinal) releases;
        tip = builtins.elemAt releases (length releases - 1);
        setId = tip.batch.release;
        qualification = tip.qualification;
        profileIds = sorted (qualification.requiredGenericProfiles or [ ]);
        platformNames = sorted (attrNames (qualification.platforms or { }));
        platforms = map (
          id: normalizePlatform "${context} platform ${id}" id qualification.platforms.${id}
        ) platformNames;
        selectedFixIds = concatMap (entry: map (fix: fix.id) entry.batch.fixes) releases;
        oracleManifests = concatMap (entry: entry.qualification.oracles) releases;
        oracleFixIds = map (manifest: manifest.fixId) oracleManifests;
        oracles = concatMap (
          manifest:
          map (
            oracle:
            normalizeOracle "${context} oracle ${manifest.fixId}/${oracle.id or "<unknown>"}" manifest.fixId
              oracle
          ) manifest.oracles
        ) oracleManifests;
        oracleIds = map (oracle: oracle.id) oracles;
        releaseSummaries = map (entry: {
          inherit (entry.batch)
            payloadRevision
            release
            ;
          kernelVersion = entry.batch.kernelTarget.kernelVersion;
          releaseOrdinal = entry.batch.unameLevel.releaseOrdinal;
        }) releases;
        members = map (
          entry:
          let
            batch = entry.batch;
          in
          checked
            [
              (require "${context} member ${batch.release}" (builtins.hasAttr batch.release producerAttrs)
                "producer attribute is missing"
              )
              (require "${context} member ${batch.release}" (isString
                producerAttrs.${batch.release}
              ) "producer attribute must be non-empty")
            ]
            {
              release = batch.release;
              kernelVersion = batch.kernelTarget.kernelVersion;
              payloadRevision = batch.payloadRevision;
              releaseOrdinal = batch.unameLevel.releaseOrdinal;
              predecessorRelease =
                if batch.lineage.predecessorBatch == null then null else batch.lineage.predecessorBatch.release;
              producerAttr = producerAttrs.${batch.release};
              fixIds = map (fix: fix.id) batch.fixes;
              oracleIds = batch.oracleIds;
            }
        ) releases;

        genericRows = concatMap (
          profileId:
          map (
            platform:
            let
              profile = genericProfiles.${profileId};
              rowId = "${setId}--${rowComponent profileId}--${platform.id}";
            in
            profile
            // {
              inherit
                platform
                profileId
                rowId
                setId
                ;
              oracleIds = [ ];
              oracleShard = "none";
              runnerClass = platform.runnerClass;
              supported = platform.supported;
              expectedOutcome = if platform.supported then profile.expectedOutcome else "blocked";
            }
          ) platforms
        ) profileIds;
        oracleRows = concatMap (
          oracle:
          map (
            platformId:
            let
              platform = findFirst (candidate: candidate.id == platformId) null platforms;
              rowId = "${setId}--fix-${rowComponent oracle.fixId}-${rowComponent oracle.id}--${platformId}";
            in
            checked
              [
                (require "${context} oracle ${oracle.id} platform ${platformId}" (
                  platform != null
                ) "applicable platform did not resolve")
              ]
              (
                oracle
                // {
                  inherit
                    platform
                    platformId
                    rowId
                    setId
                    ;
                  profileId = "fix/${oracle.fixId}/${oracle.id}";
                  template = "kernel/livepatch-fix";
                  oracleIds = [ oracle.id ];
                  oracleShard = oracle.id;
                  runnerClass = platform.runnerClass;
                  supported = platform.supported;
                  expectedOutcome = if platform.supported then oracle.expectedOutcome else "blocked";
                }
                // optionalAttrs (platform ? unsupportedReason) {
                  inherit (platform) unsupportedReason;
                }
              )
          ) oracle.platforms
        ) oracles;
        rows = genericRows ++ oracleRows;
        rowIds = map (row: row.rowId) rows;
        compactRows = map (row: {
          inherit (row)
            expectedOutcome
            profileId
            rowId
            runnerClass
            setId
            timeoutClass
            ;
        }) rows;
        coverage = concatMap (
          row:
          map (oracleId: {
            inherit (row)
              profileId
              rowId
              setId
              ;
            inherit oracleId;
            platformId = row.platformId;
          }) row.oracleIds
        ) oracleRows;
        expectedCoverageCount = length oracleRows;
      in
      checked
        [
          (require context (
            (qualification.schemaVersion or null) == 1
          ) "qualification schemaVersion must be 1")
          (require context (
            (qualification.release or null) == tip.batch.release
          ) "qualification release must match the tip")
          (require context (profileIds == requiredProfileIds) "required generic profiles are incomplete")
          (require context (platformNames == requiredPlatformIds) "AMD and Intel platforms are mandatory")
          (require context (uniqueList releaseIds) "release IDs must be unique")
          (require context (uniqueList ordinals) "release ordinals must be unique")
          (require context (
            ordinals == genList (index: index + 1) (length ordinals)
          ) "release ordinals must be contiguous from one")
          (require context (selectedFixIds != [ ]) "selected set must contain a fix")
          (require context (uniqueList selectedFixIds) "fix IDs must be unique across the active set")
          (require context (
            sorted selectedFixIds == sorted oracleFixIds
          ) "every active fix must have one oracle manifest")
          (require context (uniqueList oracleIds) "oracle IDs must be unique across the active set")
          (require context (all (
            row:
            row.platform.id == row.platformId
            && row.runnerClass == row.platform.runnerClass
            && row.supported == row.platform.supported
            && (
              if row.platform.supported then
                !(row ? unsupportedReason)
              else
                row.expectedOutcome == "blocked"
                && (row.unsupportedReason or null) == row.platform.unsupportedReason
            )
          ) oracleRows) "oracle platform mapping is inconsistent")
          (require context (all (
            fixId: builtins.elem fixId oracleFixIds
          ) selectedFixIds) "active fix oracle coverage is incomplete")
          (require context (uniqueList rowIds) "row IDs must be unique")
          (require context (all (
            row:
            row.oracleIds == [ ]
            && row.oracleShard == "none"
            && row.validator == "builtin/generic-livepatch-safety-v1"
          ) genericRows) "generic rows must not select fix oracles")
          (require context (length rows <= 256) "matrix exceeds 256 rows")
          (require context (length coverage == expectedCoverageCount) "coverage tuple count mismatch")
          (require context (
            sourceRevision == null || isString sourceRevision
          ) "sourceRevision must be null or non-empty")
        ]
        {
          schemaVersion = 1;
          dormant = false;
          selectedSets = 1;
          releases = releaseSummaries;
          inherit rows coverage;
          sets = [
            {
              id = setId;
              inherit members oracleIds oracles;
              kernelVersion = target.kernelVersion;
              tipRelease = tip.batch.release;
              targetRequirements = {
                kernelVersion = target.kernelVersion;
                mode = "additive";
                unameProtocol = "vpsadminos-additive-uname-v1";
              };
            }
          ];
          matrix.include = compactRows;
          counts = {
            catalogReleases = length releases;
            normalizedReleases = length releases;
            plannedMembers = length members;
            requiredProfilePlatformTuples = length genericRows;
            activeOracles = length oracleIds;
            coverageTuples = length coverage;
            plannedRows = length rows;
            matrixRows = length compactRows;
          };
          inherit sourceRevision system;
        };
in
if plan then
  planned
else
  {
    schemaVersion = 1;
    selectedSets = if releases == [ ] then 0 else 1;
    inherit releases;
  }
