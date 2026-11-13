{ lib }:

let
  inherit (lib)
    all
    attrNames
    concatMap
    concatStrings
    concatStringsSep
    filter
    findFirst
    foldl'
    hasPrefix
    hasSuffix
    imap0
    init
    last
    length
    mapAttrsToList
    optionalAttrs
    removeSuffix
    replaceStrings
    reverseList
    sort
    splitString
    unique
    ;

  fail = context: message: throw "livepatch ${context}: ${message}";

  require =
    context: condition: message:
    if condition then true else fail context message;

  checked = checks: value: builtins.deepSeq checks value;

  onlyAttrs =
    context: allowed: value:
    let
      unexpected = filter (name: !(builtins.elem name allowed)) (attrNames value);
    in
    require context (
      unexpected == [ ]
    ) "unexpected attributes: ${builtins.concatStringsSep ", " unexpected}";

  isNonEmptyString = value: builtins.isString value && value != "";

  validId =
    value: isNonEmptyString value && builtins.match "[a-z0-9]([a-z0-9-]*[a-z0-9])?" value != null;

  validStableId =
    value: isNonEmptyString value && builtins.match "[a-z0-9]([a-z0-9._:-]*[a-z0-9])?" value != null;

  releaseParts =
    context: release:
    let
      parts = splitString "." release;
      ordinalText = if parts == [ ] then "" else last parts;
      kernelParts = if parts == [ ] then [ ] else init parts;
      kernelVersion = concatStringsSep "." kernelParts;
      releaseOrdinal =
        if builtins.match "[1-9][0-9]*" ordinalText == null then 0 else builtins.fromJSON ordinalText;
    in
    checked
      [
        (require context (isNonEmptyString release) "release must be a non-empty string")
        (require context (
          length kernelParts >= 2
        ) "release must contain a numeric kernel version and ordinal")
        (require context (
          builtins.match "[0-9]+(\\.[0-9]+)+" kernelVersion != null
        ) "release kernel version must contain only numeric components")
        (require context (releaseOrdinal > 0) "release ordinal must be a positive integer")
      ]
      {
        inherit kernelVersion releaseOrdinal;
      };

  releaseLessThan =
    left: right:
    let
      leftParts = releaseParts "release ${left}" left;
      rightParts = releaseParts "release ${right}" right;
    in
    if leftParts.kernelVersion == rightParts.kernelVersion then
      leftParts.releaseOrdinal < rightParts.releaseOrdinal
    else
      leftParts.kernelVersion < rightParts.kernelVersion;

  unameProtocol = "vpsadminos-additive-uname-v1";
  unameStateId = "0x48573a1786d6fe85";
  unameStateVersion = 1;
  unameGuardErrno = "-ESTALE";
  unameFrameworkPath = ./framework/release-level.patch;
  frozenUnameFrameworkSha256 = "46c9e631d4c8a767e32d49e3ee1e8cef7ca43f926628cd9c817e7fd47983a597";
  unameFrameworkSha256 = builtins.hashFile "sha256" unameFrameworkPath;
  unameCallbackCarrier = {
    source = "kernel/bpf/core.c";
    object = "kernel/bpf/core.o";
    livepatchObject = "vmlinux";
  };
  unameStateSection = {
    recordSize = 24;
    alignment = 8;
    sentinel = {
      id = "0x0000000000000000";
      version = 0;
      data = "0x0000000000000000";
      size = 24;
      zero = true;
    };
  };

  isFullCommit = value: isNonEmptyString value && builtins.match "[0-9a-f]{40}" value != null;

  uniqueList = values: length (unique values) == length values;

  sortStrings = sort builtins.lessThan;

  functionKey =
    function:
    builtins.toJSON {
      inherit (function) object symbol sympos;
    };

  sortFunctions = sort (left: right: functionKey left < functionKey right);

  normalizeFunction =
    context: function:
    checked
      [
        (require context (builtins.isAttrs function) "function must be an attribute set")
        (onlyAttrs context [ "object" "symbol" "sympos" ] function)
        (require context (isNonEmptyString function.object) "object must be a non-empty string")
        (require context (isNonEmptyString function.symbol) "symbol must be a non-empty string")
        (require context (
          builtins.isInt function.sympos && function.sympos >= 0
        ) "sympos must be a non-negative integer")
      ]
      {
        inherit (function) object symbol sympos;
      };

  normalizeReference =
    context: reference:
    checked
      [
        (require context (builtins.isAttrs reference) "reference must be an attribute set")
        (onlyAttrs context [ "payloadRevision" "release" ] reference)
        (releaseParts "${context}.release" reference.release)
        (require context (
          builtins.isInt reference.payloadRevision && reference.payloadRevision > 0
        ) "payloadRevision must be a positive integer")
      ]
      {
        inherit (reference) payloadRevision release;
      };

  normalizeStringList =
    context: values:
    checked [
      (require context (builtins.isList values) "value must be a list")
      (require context (all isNonEmptyString values) "entries must be non-empty strings")
      (require context (uniqueList values) "entries must be unique")
    ] (sortStrings values);

  normalizeFunctionList =
    context: values:
    let
      normalized = imap0 (index: normalizeFunction "${context}[${toString index}]") values;
      keys = map functionKey normalized;
    in
    checked [
      (require context (builtins.isList values) "value must be a list")
      (require context (uniqueList keys) "functions must be unique by object, symbol and sympos")
    ] (sortFunctions normalized);

  normalizeIdentity =
    context: identity:
    let
      values = mapAttrsToList (_name: value: value) identity;
    in
    checked [
      (require context (builtins.isAttrs identity) "identity must be an attribute set")
      (require context (attrNames identity != [ ]) "identity must not be empty")
      (require context (all isNonEmptyString values) "identity values must be non-empty strings")
    ] identity;

  normalizeSignature =
    context: signature:
    checked
      [
        (require context (builtins.isAttrs signature) "signature policy must be an attribute set")
        (onlyAttrs context [ "required" "sigId" "sigKey" "signer" ] signature)
        (require context (builtins.isBool signature.required) "required must be a boolean")
        (require context (
          if signature.required then
            isNonEmptyString signature.signer
            && isNonEmptyString signature.sigId
            && isNonEmptyString signature.sigKey
          else
            signature.signer == null && signature.sigId == null && signature.sigKey == null
        ) "signature fields do not match the explicit target policy")
      ]
      {
        inherit (signature)
          required
          sigId
          sigKey
          signer
          ;
      };

  normalizeTarget =
    context: target:
    checked
      [
        (require context (builtins.isAttrs target) "kernel target must be an attribute set")
        (onlyAttrs context [ "id" "identity" "kernelVersion" "signature" "vermagic" ] target)
        (require context (validId target.id) "id is invalid")
        (require context (isNonEmptyString target.kernelVersion) "kernelVersion must be a non-empty string")
        (require context (
          builtins.match "[0-9]+(\\.[0-9]+)+" target.kernelVersion != null
        ) "kernelVersion must contain only numeric components")
        (require context (isNonEmptyString target.vermagic) "vermagic must be a non-empty exact value")
      ]
      {
        inherit (target) id kernelVersion vermagic;
        identity = normalizeIdentity "${context}.identity" target.identity;
        signature = normalizeSignature "${context}.signature" target.signature;
      };

  mkConfiguredTarget =
    {
      kernel,
      kernelVersion,
      toolchain,
      zfsBuiltinPkg,
    }:
    let
      context = "configured kernel target";
      kernelConfig = kernel.config or (fail context "kernel package is missing config metadata");
      hasConfig =
        name:
        if kernelConfig ? isSet then
          kernelConfig.isSet name
        else
          builtins.hasAttr "CONFIG_${name}" kernelConfig;
      configValue =
        name:
        if kernelConfig ? getValue then
          kernelConfig.getValue name
        else
          kernelConfig."CONFIG_${name}" or null;
      requiredConfigNames = [
        "GCC_PLUGIN_RANDSTRUCT"
        "MODVERSIONS"
        "MODULE_SIG_FORCE"
        "MODULE_UNLOAD"
        "PREEMPT_BUILD"
        "PREEMPT_RT"
        "RANDSTRUCT_FULL"
        "RANDSTRUCT_PERFORMANCE"
        "SMP"
      ];
      configIsYes = name: configValue name == "y";
      randstructEnabled = builtins.any configIsYes [
        "GCC_PLUGIN_RANDSTRUCT"
        "RANDSTRUCT_FULL"
        "RANDSTRUCT_PERFORMANCE"
      ];
      hostPlatform = kernel.stdenv.hostPlatform or { };
      linuxArch = hostPlatform.linuxArch or null;
      architectureVermagic = if linuxArch == "x86_64" then "" else null;
      vermagicFeatureTokens = [
        (if configIsYes "SMP" then "SMP" else "")
        (
          if configIsYes "PREEMPT_BUILD" then
            "preempt"
          else if configIsYes "PREEMPT_RT" then
            "preempt_rt"
          else
            ""
        )
        (if configIsYes "MODULE_UNLOAD" then "mod_unload" else "")
        (if configIsYes "MODVERSIONS" then "modversions" else "")
      ]
      ++ (if architectureVermagic == null then [ ] else [ architectureVermagic ]);
      vermagic = concatStringsSep " " (
        [ kernel.modDirVersion ] ++ filter (token: token != "") vermagicFeatureTokens
      );
      signature = {
        required = false;
        sigId = null;
        sigKey = null;
        signer = null;
      };
      identity = {
        kernelOut = toString kernel;
        kernelDev = toString kernel.dev;
        kernelSource = toString kernel.src;
        configFile = toString kernel.configfile;
        moduleSymvers = "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build/Module.symvers";
        toolchain = toString toolchain;
        vmlinux = "${kernel.dev}/vmlinux";
        zfsBuiltin = if zfsBuiltinPkg == null then "absent" else toString zfsBuiltinPkg;
      };
      identityDigest = builtins.hashString "sha256" (builtins.toJSON identity);
      targetId = "configured-${replaceStrings [ "." ] [ "-" ] kernelVersion}-${
        builtins.substring 0 12 identityDigest
      }";
      kernelTarget = {
        id = targetId;
        inherit
          identity
          kernelVersion
          signature
          vermagic
          ;
      };
      targetBuild = {
        modDirVersion = kernel.modDirVersion;
        source = kernel.src;
        dev = kernel.dev;
        configFile = kernel.configfile;
        vmlinux = "${kernel.dev}/vmlinux";
        nativeBuildInputs = kernel.nativeBuildInputs or [ ];
        inherit
          identity
          signature
          toolchain
          vermagic
          zfsBuiltinPkg
          ;
      };
    in
    checked
      [
        (require context (builtins.isAttrs kernel) "kernel must be an attribute set")
        (require context (isNonEmptyString kernelVersion) "kernelVersion must be a non-empty string")
        (require context (
          builtins.match "[0-9]+(\\.[0-9]+)+" kernelVersion != null
        ) "kernelVersion must contain only numeric components")
        (require context (kernel ? modDirVersion) "kernel package is missing modDirVersion")
        (require context (
          kernel.modDirVersion == kernelVersion
        ) "kernelVersion does not match the configured kernel module directory")
        (require context (
          kernel ? src && kernel ? dev && kernel ? configfile
        ) "kernel package is missing source, dev or configfile inputs")
        (require context (
          kernel ? stdenv && kernel.stdenv ? hostPlatform
        ) "kernel package is missing host platform metadata")
        (require context (builtins.all hasConfig requiredConfigNames)
          "kernel config is missing a vermagic or signature component"
        )
        (require context (builtins.all (
          name:
          builtins.elem (configValue name) [
            "n"
            "y"
          ]
        ) requiredConfigNames) "kernel config metadata must contain exact y/n values")
        (require context (architectureVermagic != null) "kernel architecture vermagic is unsupported")
        (require context (
          !randstructEnabled
        ) "RANDSTRUCT vermagic is unsupported without an exact generated seed hash")
        (require context (
          !configIsYes "MODULE_SIG_FORCE"
        ) "forced module signatures are unsupported without an exact signing contract")
      ]
      {
        inherit kernelTarget targetBuild;
      };

  normalizeBuilder =
    builder:
    checked
      [
        (require "builder" (builtins.isAttrs builder) "builder must be an attribute set")
        (onlyAttrs "builder" [ "kpatchBuild" "kpatchRevision" ] builder)
        (require "builder" (isNonEmptyString builder.kpatchBuild) "kpatchBuild must be a non-empty string")
        (require "builder" (isNonEmptyString builder.kpatchRevision)
          "kpatchRevision must be a non-empty string"
        )
      ]
      {
        inherit (builder) kpatchBuild kpatchRevision;
        flags = [ "--non-replace" ];
      };

  normalizeSource =
    context: source:
    checked
      [
        (require context (builtins.isAttrs source) "source must be an attribute set")
        (onlyAttrs context [ "commit" "repository" ] source)
        (require context (isNonEmptyString source.repository) "repository must be a non-empty string")
        (require context (
          builtins.match "[a-z0-9._-]+/[a-z0-9._-]+" source.repository != null
        ) "repository must be a canonical owner/name identity")
        (require context (isFullCommit source.commit)
          "commit must be a full 40-character hexadecimal identity"
        )
      ]
      {
        inherit (source) commit repository;
      };

  normalizeProvenance =
    context: provenance:
    let
      hasUpstream = provenance ? upstream;
      hasStable = provenance ? stable;
      upstream = provenance.upstream or null;
      stable = provenance.stable or null;
      validTriState = value: value == null || isFullCommit value;
    in
    checked
      [
        (require context (builtins.isAttrs provenance) "provenance must be an attribute set")
        (onlyAttrs context [ "source" "stable" "status" "upstream" ] provenance)
        (require context (builtins.elem provenance.status [
          "downstream-only"
          "stable"
          "upstream"
        ]) "status is invalid")
        (require context (
          !hasUpstream || validTriState upstream
        ) "upstream must be omitted, null or a full commit")
        (require context (
          !hasStable || validTriState stable
        ) "stable must be omitted, null or a full commit")
        (require context (
          if provenance.status == "downstream-only" then
            hasUpstream && upstream == null && hasStable && stable == null
          else if provenance.status == "upstream" then
            hasUpstream && isFullCommit upstream
          else
            hasStable && isFullCommit stable && (!hasUpstream || validTriState upstream)
        ) "upstream/stable identities do not match provenance status")
      ]
      (
        {
          source = normalizeSource "${context}.source" provenance.source;
          inherit (provenance) status;
        }
        // optionalAttrs hasUpstream { inherit upstream; }
        // optionalAttrs hasStable { inherit stable; }
      );

  readFlatFiles =
    context: directory: suffix:
    let
      entries = builtins.readDir directory;
      names = sortStrings (attrNames entries);
      invalid = filter (name: entries.${name} != "regular" || !hasSuffix suffix name) names;
    in
    checked [
      (require context (
        invalid == [ ]
      ) "entries must be flat ${suffix} files: ${concatStringsSep ", " invalid}")
    ] names;

  discoverFixes =
    directory:
    map (
      name:
      let
        context = "fix descriptor ${name}";
        id = removeSuffix ".nix" name;
        descriptor = import (directory + "/${name}");
      in
      checked [
        (require context (validStableId id) "filename stem is invalid")
        (require context (builtins.isAttrs descriptor) "descriptor must be an attribute set")
        (require context ((descriptor.id or null) == id) "filename stem must equal descriptor id")
      ] descriptor
    ) (readFlatFiles "fix descriptor directory" directory ".nix");

  discoverOracleManifests =
    directory:
    map (
      name:
      let
        context = "oracle manifest ${name}";
        fixId = removeSuffix ".nix" name;
        manifest = import (directory + "/${name}");
      in
      checked [
        (require context (validStableId fixId) "filename stem is invalid")
        (require context (builtins.isAttrs manifest) "manifest must be an attribute set")
        (require context ((manifest.fixId or null) == fixId) "filename stem must equal manifest fixId")
      ] manifest
    ) (readFlatFiles "oracle manifest directory" directory ".nix");

  validateOracleClosure =
    context: fixes: manifests:
    let
      fixIds = map (fix: fix.id) fixes;
      normalized = map (
        manifest:
        let
          oracleContext = "${context} oracle manifest ${manifest.fixId or "<unknown>"}";
          oracles = manifest.oracles or [ ];
          oracleIds = map (oracle: oracle.id or "") oracles;
          fix = findFirst (candidate: candidate.id == (manifest.fixId or null)) null fixes;
        in
        checked [
          (require oracleContext (builtins.isAttrs manifest) "manifest must be an attribute set")
          (require oracleContext ((manifest.schemaVersion or null) == 1) "schemaVersion must be 1")
          (require oracleContext (builtins.isList oracles) "oracles must be a list")
          (require oracleContext (all builtins.isAttrs oracles) "oracles must contain attribute sets")
          (require oracleContext (all validStableId oracleIds) "oracle IDs are invalid")
          (require oracleContext (uniqueList oracleIds) "oracle IDs must be unique")
          (require oracleContext (fix != null) "manifest does not belong to a selected fix")
          (require oracleContext (
            sortStrings oracleIds == fix.oracleIds
          ) "manifest oracle IDs must exactly match the fix descriptor")
        ] manifest
      ) manifests;
      oracleFixIds = map (manifest: manifest.fixId) normalized;
    in
    checked [
      (require context (uniqueList oracleFixIds) "oracle manifests must be unique by fixId")
      (require context (
        sortStrings oracleFixIds == sortStrings fixIds
      ) "every selected fix must have exactly one oracle manifest")
    ] normalized;

  validateBatchUnit =
    {
      directory,
      directoryName,
      unit,
    }:
    let
      context = "release ${directoryName}";
      fixesDirectory = directory + "/fixes";
      patchesDirectory = directory + "/patches";
      qualificationDirectory = directory + "/qualification";
      discoveredFixes = discoverFixes fixesDirectory;
      discoveredSeries = import (directory + "/series.nix");
      discoveredOracles = discoverOracleManifests (qualificationDirectory + "/oracles");
      batch = unit.batch or { };
      fixIds = map (fix: fix.id or "") discoveredFixes;
      patchFileNames = readFlatFiles "${context} patch directory" patchesDirectory ".patch";
      normalizedSeries = imap0 (
        index: entry:
        let
          entryContext = "${context} series[${toString index}]";
          fixIdsForPatch = normalizeStringList "${entryContext}.fixIds" (entry.fixIds or [ ]);
        in
        checked
          [
            (require entryContext (builtins.isAttrs entry) "entry must be an attribute set")
            (onlyAttrs entryContext [ "fixIds" "id" "path" ] entry)
            (require entryContext (validStableId (entry.id or "")) "id is invalid")
            (require entryContext (builtins.typeOf (entry.path or null) == "path") "path must be a path")
            (require entryContext (fixIdsForPatch != [ ]) "fixIds must not be empty")
            (require entryContext (all (
              fixId: builtins.elem fixId fixIds
            ) fixIdsForPatch) "fixIds contain an unknown fix")
          ]
          {
            inherit (entry) id path;
            fixIds = fixIdsForPatch;
          }
      ) discoveredSeries;
      seriesIds = map (entry: entry.id) normalizedSeries;
      seriesPaths = map (entry: toString entry.path) normalizedSeries;
      expectedPatchPaths = map (name: toString (patchesDirectory + "/${name}")) patchFileNames;
      normalizedFixes = map (
        fix:
        let
          fixContext = "${context} fix ${fix.id}";
          patchIds = normalizeStringList "${fixContext}.patchIds" (fix.patchIds or [ ]);
          ownedSeriesIds = sortStrings (
            map (entry: entry.id) (filter (entry: builtins.elem fix.id entry.fixIds) normalizedSeries)
          );
        in
        checked [
          (require fixContext (patchIds != [ ]) "patchIds must not be empty")
          (require fixContext (
            patchIds == ownedSeriesIds
          ) "descriptor patchIds must exactly match series ownership")
        ] (fix // { inherit patchIds; })
      ) discoveredFixes;
      normalizedOracleManifests = validateOracleClosure context normalizedFixes discoveredOracles;
      oracleFixIds = map (manifest: manifest.fixId) normalizedOracleManifests;
      release = batch.release or "";
      parsedRelease = releaseParts "${context}.batch.release" release;
      qualification = unit.qualification or { };
      documentation = unit.documentation or { };
    in
    checked
      [
        (require context (builtins.isAttrs unit) "unit must be an attribute set")
        (onlyAttrs context [ "batch" "documentation" "qualification" ] unit)
        (require context (builtins.isAttrs batch) "batch must be an attribute set")
        (require context (release == directoryName) "directory name must equal batch release")
        (require context (
          (batch.kernelVersion or null) == parsedRelease.kernelVersion
        ) "batch kernelVersion must equal the release base version")
        (require context (
          (batch.fixes or null) == discoveredFixes
        ) "batch fixes must come from deterministic flat discovery")
        (require context (
          (batch.patches or null) == discoveredSeries
        ) "batch patches must come from series.nix")
        (require context (builtins.isList discoveredSeries) "series.nix must return a list")
        (require context (uniqueList seriesIds) "series patch IDs must be unique")
        (require context (uniqueList seriesPaths) "series patch paths must be unique")
        (require context (
          sortStrings seriesPaths == sortStrings expectedPatchPaths
        ) "series must reference every flat patch file exactly once")
        (require context (uniqueList fixIds) "fix IDs must be unique")
        (require context (
          sortStrings oracleFixIds == sortStrings fixIds
        ) "every selected fix must have exactly one oracle manifest")
        (require context (builtins.isAttrs qualification) "qualification must be an attribute set")
        (require context (
          (qualification.schemaVersion or null) == 1
        ) "qualification schemaVersion must be 1")
        (require context (
          (qualification.release or null) == release
        ) "qualification release must match the batch")
        (require context (builtins.isAttrs documentation) "documentation must be an attribute set")
        (onlyAttrs "${context}.documentation" [ "anchor" "page" ] documentation)
        (require context (isNonEmptyString (
          documentation.page or ""
        )) "documentation page must be a non-empty string")
        (require context (isNonEmptyString (
          documentation.anchor or ""
        )) "documentation anchor must be a non-empty string")
      ]
      {
        batch = batch // {
          fixes = normalizedFixes;
          patches = normalizedSeries;
        };
        inherit documentation;
        qualification = qualification // {
          oracles = normalizedOracleManifests;
        };
      };

  discoverCatalog =
    directory:
    let
      entries = builtins.readDir directory;
      names = sortStrings (attrNames entries);
      releaseNames = filter (name: entries.${name} == "directory") names;
      unexpected = filter (
        name: !(entries.${name} == "directory" || (name == "default.nix" && entries.${name} == "regular"))
      ) names;
      sortedReleases = sort releaseLessThan releaseNames;
    in
    checked
      [
        (require "catalog" (unexpected == [ ]) "unexpected entries: ${concatStringsSep ", " unexpected}")
      ]
      (
        map (
          release:
          let
            releaseDirectory = directory + "/${release}";
            unit = import (releaseDirectory + "/default.nix") { batchLib = livepatchLib; };
          in
          validateBatchUnit {
            directory = releaseDirectory;
            directoryName = release;
            inherit unit;
          }
        ) sortedReleases
      );

  batchReference = batch: {
    inherit (batch)
      inputDigest
      moduleName
      payloadRevision
      release
      releaseOrdinal
      ;
  };

  referenceMatches =
    reference: batch:
    reference.release == batch.release && reference.payloadRevision == batch.payloadRevision;

  functionInBatch = key: batch: builtins.elem key (map functionKey batch.build.expected.functions);

  findLatestFunctionOwner =
    key: predecessors: findFirst (batch: functionInBatch key batch) null (reverseList predecessors);

  normalizeBatch =
    {
      builder,
      descriptor,
      predecessors ? [ ],
      target,
    }:
    let
      context = "release ${descriptor.release or "<unknown>"}";
      normalizedBuilder = normalizeBuilder builder;
      normalizedTarget = normalizeTarget "${context}.kernelTarget" target;

      parsedRelease = releaseParts "${context}.release" (descriptor.release or "");
      releaseOrdinal = parsedRelease.releaseOrdinal;
      predecessorOrdinal = if releaseOrdinal == 1 then null else releaseOrdinal - 1;
      publishedRelease = descriptor.release;
      rollbackRelease =
        if predecessorOrdinal == null then
          normalizedTarget.kernelVersion
        else
          "${normalizedTarget.kernelVersion}.${toString predecessorOrdinal}";
      callbackPrefix = "vpsadminos_uname_level_p${toString releaseOrdinal}";
      frameworkCallbacks = [
        {
          kind = "pre_patch";
          object = unameCallbackCarrier.livepatchObject;
          symbol = "${callbackPrefix}_pre_patch";
        }
        {
          kind = "post_patch";
          object = unameCallbackCarrier.livepatchObject;
          symbol = "${callbackPrefix}_post_patch";
        }
        {
          kind = "post_unpatch";
          object = unameCallbackCarrier.livepatchObject;
          symbol = "${callbackPrefix}_post_unpatch";
        }
      ];
      frameworkStates = [
        {
          id = unameStateId;
          version = unameStateVersion;
          data = "0x0000000000000000";
        }
      ];
      targetIdentitySha256 = builtins.hashString "sha256" (builtins.toJSON normalizedTarget);
      generatedHeader = ''
        #ifndef VPSADMINOS_LIVEPATCH_BUILD_H
        #define VPSADMINOS_LIVEPATCH_BUILD_H
        #define LIVEPATCH_ORIG_KERNEL_VERSION "${normalizedTarget.kernelVersion}"
        #define LIVEPATCH_NAME "${descriptor.release}"
        #define VPSADMINOS_LIVEPATCH_UNAME_PROTOCOL "${unameProtocol}"
        #define VPSADMINOS_LIVEPATCH_UNAME_BASE_RELEASE "${normalizedTarget.kernelVersion}"
        #define VPSADMINOS_LIVEPATCH_UNAME_RELEASE_ORDINAL ${toString releaseOrdinal}
        #define VPSADMINOS_LIVEPATCH_UNAME_PREDECESSOR_ORDINAL ${
          toString (if predecessorOrdinal == null then 0 else predecessorOrdinal)
        }
        #define VPSADMINOS_LIVEPATCH_UNAME_STATE_ID ${unameStateId}UL
        #define VPSADMINOS_LIVEPATCH_UNAME_STATE_VERSION ${toString unameStateVersion}U
        #define VPSADMINOS_LIVEPATCH_PAYLOAD_REVISION ${toString descriptor.payloadRevision}
        #define VPSADMINOS_LIVEPATCH_TARGET_IDENTITY_SHA256 "${targetIdentitySha256}"
        #define VPSADMINOS_LIVEPATCH_FRAMEWORK_PATCH_SHA256 "${unameFrameworkSha256}"
        #endif
      '';
      generatedHeaderSha256 = builtins.hashString "sha256" generatedHeader;
      normalizedUnameLevel = {
        protocol = unameProtocol;
        baseRelease = normalizedTarget.kernelVersion;
        frameworkPatchSha256 = unameFrameworkSha256;
        inherit
          generatedHeaderSha256
          predecessorOrdinal
          publishedRelease
          releaseOrdinal
          rollbackRelease
          ;
        stateId = unameStateId;
        stateVersion = unameStateVersion;
        guardErrno = unameGuardErrno;
        callbackCarrier = unameCallbackCarrier;
        callbacks = frameworkCallbacks;
      };
      frameworkBuild = {
        name = builtins.baseNameOf (toString unameFrameworkPath);
        order = length descriptor.patches;
        sha256 = unameFrameworkSha256;
      };

      expected = descriptor.build.expected;
      expectedFunctions = normalizeFunctionList "${context}.build.expected.functions" expected.functions;
      expectedFunctionKeys = map functionKey expectedFunctions;
      expectedImports = normalizeStringList "${context}.build.expected.imports" expected.imports;
      expectedRelocations = normalizeStringList "${context}.build.expected.relocations" expected.relocations;
      targets = normalizeStringList "${context}.build.targets" descriptor.build.targets;

      patches = imap0 (
        index: patch:
        let
          patchContext = "${context}.patches[${toString index}]";
          patchFixIds = normalizeStringList "${patchContext}.fixIds" (patch.fixIds or [ ]);
        in
        checked
          [
            (require patchContext (builtins.isAttrs patch) "patch must be an attribute set")
            (onlyAttrs patchContext [ "fixIds" "id" "path" ] patch)
            (require patchContext (validStableId (patch.id or "")) "patch id is invalid")
            (require patchContext (builtins.typeOf patch.path == "path") "patch must be a path")
          ]
          {
            inherit (patch) id path;
            fixIds = patchFixIds;
            name = builtins.baseNameOf (toString patch.path);
            order = index;
            sha256 = builtins.hashFile "sha256" patch.path;
          }
      ) descriptor.patches;
      patchManifest = map (patch: removeAttrs patch [ "path" ]) patches;
      patchIds = map (patch: patch.id) patches;

      fixes = imap0 (
        index: fix:
        let
          fixContext = "${context}.fixes[${toString index}]";
          functions = normalizeFunctionList "${fixContext}.functions" fix.functions;
          provenance = fix.provenance;
        in
        checked
          [
            (require fixContext (builtins.isAttrs fix) "fix must be an attribute set")
            (onlyAttrs fixContext [
              "cves"
              "functions"
              "id"
              "oracleIds"
              "patchIds"
              "prerequisites"
              "provenance"
            ] fix)
            (require fixContext (validStableId fix.id) "id is invalid")
            (require fixContext (functions != [ ]) "functions must not be empty")
          ]
          {
            inherit (fix) id;
            cves = normalizeStringList "${fixContext}.cves" fix.cves;
            inherit functions;
            oracleIds = normalizeStringList "${fixContext}.oracleIds" fix.oracleIds;
            patchIds = normalizeStringList "${fixContext}.patchIds" fix.patchIds;
            prerequisites = normalizeStringList "${fixContext}.prerequisites" fix.prerequisites;
            provenance = normalizeProvenance "${fixContext}.provenance" provenance;
          }
      ) descriptor.fixes;

      fixIds = map (fix: fix.id) fixes;
      oracleIds = sortStrings (unique (concatMap (fix: fix.oracleIds) fixes));
      fixFunctionKeys = unique (concatMap (fix: map functionKey fix.functions) fixes);
      patchOwnershipMatches = all (
        fix:
        fix.patchIds
        == sortStrings (map (patch: patch.id) (filter (patch: builtins.elem fix.id patch.fixIds) patches))
      ) fixes;

      authoredPredecessor =
        if descriptor.lineage.predecessorBatch == null then
          null
        else
          normalizeReference "${context}.lineage.predecessorBatch" descriptor.lineage.predecessorBatch;

      immediatePredecessor =
        if authoredPredecessor == null then
          null
        else
          findFirst (batch: referenceMatches authoredPredecessor batch) null predecessors;
      existingDirectSuccessor =
        if authoredPredecessor == null then
          null
        else
          findFirst (
            batch:
            batch.lineage.predecessorBatch != null
            && referenceMatches batch.lineage.predecessorBatch authoredPredecessor
          ) null predecessors;
      lineageAncestorReferences =
        if immediatePredecessor == null then
          [ ]
        else
          immediatePredecessor.lineage.ancestors ++ [ (batchReference immediatePredecessor) ];
      lineagePredecessors = map (
        reference: findFirst (batch: referenceMatches reference batch) null predecessors
      ) lineageAncestorReferences;
      independentSameTarget = filter (
        batch:
        batch.kernelTarget.id == normalizedTarget.id
        && !(builtins.elem (batchReference batch) lineageAncestorReferences)
      ) predecessors;

      lineageFunctions = imap0 (
        index: entry:
        let
          entryContext = "${context}.lineage.functions[${toString index}]";
          function = normalizeFunction entryContext (removeAttrs entry [ "predecessorOwner" ]);
        in
        checked
          [
            (require entryContext (builtins.isAttrs entry) "lineage function must be an attribute set")
            (onlyAttrs entryContext [ "object" "predecessorOwner" "symbol" "sympos" ] entry)
          ]
          (
            function
            // {
              predecessorOwner = normalizeReference "${entryContext}.predecessorOwner" entry.predecessorOwner;
            }
          )
      ) descriptor.lineage.functions;
      lineageFunctionKeys = map functionKey lineageFunctions;

      ancestorFunctionKeys = unique (
        concatMap (batch: map functionKey batch.build.expected.functions) lineagePredecessors
      );
      overlappedFunctionKeys = sortStrings (
        filter (key: builtins.elem key ancestorFunctionKeys) expectedFunctionKeys
      );
      independentFunctionKeys = unique (
        concatMap (batch: map functionKey batch.build.expected.functions) independentSameTarget
      );
      unexplainedIndependentOverlap = filter (
        key: builtins.elem key independentFunctionKeys
      ) expectedFunctionKeys;

      exactLineageFunctions = map (
        entry:
        let
          key = functionKey entry;
          owner = findLatestFunctionOwner key lineagePredecessors;
        in
        checked
          [
            (require context (owner != null) "lineage function has no predecessor owner: ${key}")
            (require context (referenceMatches entry.predecessorOwner owner)
              "lineage function predecessorOwner is not the most recent owner: ${key}"
            )
          ]
          (
            (removeAttrs entry [ "predecessorOwner" ])
            // {
              predecessorOwner = batchReference owner;
            }
          )
      ) lineageFunctions;

      currentFixesFor = key: filter (fix: builtins.elem key (map functionKey fix.functions)) fixes;

      enrichedFunctions = map (
        function:
        let
          key = functionKey function;
          owner = findLatestFunctionOwner key lineagePredecessors;
          ownerFunction =
            if owner == null then
              null
            else
              findFirst (candidate: functionKey candidate == key) null owner.build.expected.functions;
          currentFixes = currentFixesFor key;
        in
        function
        // {
          oracleIds = sortStrings (
            unique (
              (if ownerFunction == null then [ ] else ownerFunction.oracleIds)
              ++ concatMap (fix: fix.oracleIds) currentFixes
            )
          );
          semanticFixes = sortStrings (
            unique (
              (if ownerFunction == null then [ ] else ownerFunction.semanticFixes)
              ++ map (fix: fix.id) currentFixes
            )
          );
        }
      ) expectedFunctions;

      predecessorIdentity =
        if immediatePredecessor == null then null else batchReference immediatePredecessor;
      normalizedLineage = {
        ancestors = lineageAncestorReferences;
        depth = length lineagePredecessors;
        predecessorBatch = predecessorIdentity;
        functions = exactLineageFunctions;
        states = [ ];
      };

      producerData = {
        schemaVersion = 1;
        batch = {
          inherit (descriptor) payloadRevision release;
          inherit releaseOrdinal;
          kernelTarget = normalizedTarget.id;
          mode = descriptor.mode;
        };
        builder = normalizedBuilder;
        expected = {
          callbacks = frameworkCallbacks;
          functions = expectedFunctions;
          imports = expectedImports;
          relocations = expectedRelocations;
          states = frameworkStates;
          stateSection = unameStateSection;
        };
        inherit fixes;
        kernelTarget = normalizedTarget;
        unameLevel = normalizedUnameLevel;
        inherit patchManifest targets;
      };
      producerDigest = builtins.hashString "sha256" (builtins.toJSON producerData);

      semanticContract = {
        inherit normalizedLineage producerDigest;
        functions = map (function: {
          inherit (function)
            object
            oracleIds
            semanticFixes
            symbol
            sympos
            ;
        }) enrichedFunctions;
      };
      inputDigest = builtins.hashString "sha256" (builtins.toJSON semanticContract);

      kernelName = concatStrings (splitString "." normalizedTarget.kernelVersion);
      moduleName = "lp_${kernelName}_${toString releaseOrdinal}_${builtins.substring 0 12 inputDigest}";
      installPath = "lib/modules/${normalizedTarget.kernelVersion}/extra/${moduleName}.ko";

      runtime = descriptor.runtime;
      normalizedExpected = {
        callbacks = frameworkCallbacks;
        functions = enrichedFunctions;
        imports = expectedImports;
        relocations = expectedRelocations;
        states = frameworkStates;
        stateSection = unameStateSection;
      };

      manifest = {
        schemaVersion = 1;
        batch = {
          inherit (descriptor) payloadRevision release;
          inherit releaseOrdinal;
        };
        builder = normalizedBuilder;
        fixes = fixes;
        inherit
          inputDigest
          installPath
          moduleName
          producerDigest
          ;
        kernelTarget = normalizedTarget;
        lineage = normalizedLineage;
        mode = "additive";
        patches = patchManifest;
        expected = normalizedExpected;
        unameLevel = normalizedUnameLevel;
        inherit targets;
      };

      checks = [
        (require context (builtins.isAttrs descriptor) "descriptor must be an attribute set")
        (onlyAttrs context [
          "build"
          "fixes"
          "kernelVersion"
          "lineage"
          "mode"
          "patches"
          "payloadRevision"
          "release"
          "runtime"
        ] descriptor)
        (require context (descriptor.release == publishedRelease) "release is invalid")
        (require context (
          builtins.isInt descriptor.payloadRevision && descriptor.payloadRevision > 0
        ) "payloadRevision must be a positive integer")
        (require context (isNonEmptyString descriptor.kernelVersion)
          "kernelVersion must be a non-empty string"
        )
        (require context (
          descriptor.kernelVersion == parsedRelease.kernelVersion
          && descriptor.kernelVersion == normalizedTarget.kernelVersion
        ) "kernelVersion does not match the configured target")
        (require context (descriptor.mode == "additive") "mode must be additive")
        (require context (
          unameFrameworkSha256 == frozenUnameFrameworkSha256
        ) "release-level framework source does not match its frozen identity")
        (require context (builtins.isAttrs descriptor.build) "build must be an attribute set")
        (onlyAttrs "${context}.build" [ "expected" "targets" ] descriptor.build)
        (require context (
          builtins.isList descriptor.patches && patches != [ ]
        ) "patches must be a non-empty list")
        (require "${context}.build" (uniqueList (
          map (patch: patch.sha256) patches
        )) "patch content must be unique")
        (require "${context}.build" (all (
          patch: patch.sha256 != unameFrameworkSha256
        ) patches) "payload patches must not duplicate the producer-owned release-level framework")
        (require "${context}.build" (targets != [ ]) "targets must not be empty")
        (require "${context}.build.expected" (builtins.isAttrs expected)
          "expected must be an attribute set"
        )
        (onlyAttrs "${context}.build.expected" [
          "callbacks"
          "functions"
          "imports"
          "relocations"
          "states"
        ] expected)
        (require "${context}.build.expected" (expectedFunctions != [ ]) "functions must not be empty")
        (require "${context}.build.expected" (
          expected.callbacks == [ ]
        ) "payload-authored callbacks are unsupported")
        (require "${context}.build.expected" (
          expected.states == [ ]
        ) "payload-authored livepatch states are unsupported")
        (require "${context}.build.expected" (all (
          name: !(hasPrefix "klp_shadow_" name || hasPrefix "kpatch_shadow_" name)
        ) expectedImports) "shadow-variable imports are unsupported")
        (require context (
          builtins.isList descriptor.fixes && fixes != [ ]
        ) "fixes must be a non-empty list")
        (require context (uniqueList fixIds) "fix IDs must be unique")
        (require context (uniqueList patchIds) "patch IDs must be unique")
        (require context (all (
          patch: patch.fixIds != [ ] && all (fixId: builtins.elem fixId fixIds) patch.fixIds
        ) patches) "series patch ownership must name selected fixes")
        (require context patchOwnershipMatches "fix patchIds must exactly match series ownership")
        (require context (
          sortStrings fixFunctionKeys == sortStrings expectedFunctionKeys
        ) "fix function ownership must cover the expected function set exactly")
        (require context (builtins.isAttrs descriptor.lineage) "lineage must be an attribute set")
        (onlyAttrs "${context}.lineage" [ "functions" "predecessorBatch" "states" ] descriptor.lineage)
        (require "${context}.lineage" (builtins.isList descriptor.lineage.functions)
          "functions must be a list"
        )
        (require "${context}.lineage" (uniqueList lineageFunctionKeys)
          "function lineage entries must be unique"
        )
        (require "${context}.lineage" (
          descriptor.lineage.states == [ ]
        ) "state lineage is unsupported for code-only batches")
        (require context (
          sortStrings lineageFunctionKeys == overlappedFunctionKeys
        ) "declared function lineage must equal the expected predecessor overlap")
        (require context (
          unexplainedIndependentOverlap == [ ]
        ) "expected functions overlap an independent same-target batch")
        (require context (
          authoredPredecessor == null || immediatePredecessor != null
        ) "predecessorBatch does not resolve to an earlier batch")
        (require context (
          authoredPredecessor == null || existingDirectSuccessor == null
        ) "predecessorBatch already has a direct successor; lineage branches are unsupported")
        (require context (
          immediatePredecessor == null || immediatePredecessor.kernelTarget.id == normalizedTarget.id
        ) "predecessorBatch must use the same kernel target")
        (require context (
          immediatePredecessor == null || immediatePredecessor.kernelTarget == normalizedTarget
        ) "predecessorBatch must use the same exact kernel target")
        (require context (
          if releaseOrdinal == 1 then authoredPredecessor == null else authoredPredecessor != null
        ) "release ordinal root/predecessor relationship is invalid")
        (require context (
          immediatePredecessor == null || immediatePredecessor.releaseOrdinal + 1 == releaseOrdinal
        ) "releaseOrdinal must immediately follow predecessorBatch")
        (require context (all (
          predecessor:
          predecessor.kernelTarget != normalizedTarget || predecessor.releaseOrdinal != releaseOrdinal
        ) predecessors) "releaseOrdinal is already selected for this kernel target")
        (require context (all (
          predecessor: predecessor != null
        ) lineagePredecessors) "predecessor ancestry is incomplete")
        (require context (all (
          predecessor: predecessor.release != descriptor.release
        ) predecessors) "release is already registered")
        (require context (builtins.isAttrs runtime) "runtime must be an attribute set")
        (onlyAttrs "${context}.runtime" [ "bootAutoload" "prevention" "recovery" "removal" ] runtime)
        (require "${context}.runtime" (
          runtime.bootAutoload == false
        ) "bootAutoload must be false for this batch class")
        (require "${context}.runtime" (isNonEmptyString runtime.prevention)
          "prevention must be a non-empty string"
        )
        (require "${context}.runtime" (isNonEmptyString runtime.removal)
          "removal must be a non-empty string"
        )
        (require "${context}.runtime" (isNonEmptyString runtime.recovery)
          "recovery must be a non-empty string"
        )
        (require context (
          builtins.stringLength moduleName <= 55
        ) "derived module name exceeds the 55-byte limit")
        (require context (
          builtins.stringLength publishedRelease <= 64 && builtins.stringLength rollbackRelease <= 64
        ) "derived uname release exceeds the 64-byte UTS release limit")
        (require context (
          builtins.match "[A-Za-z_][A-Za-z0-9_]*" moduleName != null
        ) "derived module name is invalid")
      ];
    in
    checked checks {
      inherit (descriptor) payloadRevision release;
      inherit
        inputDigest
        installPath
        manifest
        moduleName
        normalizedLineage
        oracleIds
        producerDigest
        releaseOrdinal
        runtime
        ;
      build = {
        expected = normalizedExpected;
        framework = frameworkBuild // {
          path = unameFrameworkPath;
        };
        inherit generatedHeader patches targets;
      };
      fixes = fixes;
      kernelTarget = normalizedTarget;
      lineage = normalizedLineage;
      mode = "additive";
      producer = normalizedBuilder;
      unameLevel = normalizedUnameLevel;
    };

  normalizeBatches =
    {
      builder,
      descriptors,
      target,
    }:
    let
      sortedDescriptors = sort (left: right: releaseLessThan left.release right.release) descriptors;
    in
    checked
      [
        (require "registry" (builtins.isList descriptors) "descriptors must be a list")
        (require "registry" (builtins.isAttrs target) "target must be an attribute set")
      ]
      (
        foldl' (
          normalized: descriptor:
          normalized
          ++ [
            (normalizeBatch {
              inherit builder descriptor target;
              predecessors = normalized;
            })
          ]
        ) [ ] sortedDescriptors
      );

  normalizeCatalog =
    {
      builder,
      catalog,
      target,
    }:
    let
      selectedUnits = filter (unit: unit.batch.kernelVersion == target.kernelVersion) catalog;
      normalized = normalizeBatches {
        inherit builder target;
        descriptors = map (unit: unit.batch) selectedUnits;
      };
    in
    imap0 (index: unit: {
      batch = builtins.elemAt normalized index;
      inherit (unit) documentation qualification;
    }) selectedUnits;

  livepatchLib = {
    inherit
      discoverCatalog
      discoverFixes
      functionKey
      mkConfiguredTarget
      normalizeBatch
      normalizeBatches
      normalizeCatalog
      validateOracleClosure
      validateBatchUnit
      ;
  };
in
livepatchLib
