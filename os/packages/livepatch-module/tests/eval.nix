{
  lib,
  pkgs ? null,
}:

let
  livepatchLib = import ../../../livepatches/lib.nix { inherit lib; };

  configValues = {
    CONFIG_GCC_PLUGIN_RANDSTRUCT = "n";
    CONFIG_MODVERSIONS = "y";
    CONFIG_MODULE_SIG_FORCE = "n";
    CONFIG_MODULE_UNLOAD = "y";
    CONFIG_PREEMPT_BUILD = "y";
    CONFIG_PREEMPT_RT = "n";
    CONFIG_RANDSTRUCT_FULL = "n";
    CONFIG_RANDSTRUCT_PERFORMANCE = "n";
    CONFIG_SMP = "y";
  };
  mkKernelConfig =
    values:
    values
    // {
      isSet = name: builtins.hasAttr "CONFIG_${name}" values;
      getValue = name: values."CONFIG_${name}" or null;
    };
  kernelConfig = mkKernelConfig configValues;
  mkKernel = identity: {
    outPath = "/nix/store/synthetic-kernel-${identity}";
    dev = {
      outPath = "/nix/store/synthetic-kernel-${identity}-dev";
    };
    src = "/nix/store/synthetic-kernel-source";
    configfile = "/nix/store/synthetic-kernel-config";
    config = kernelConfig;
    modDirVersion = "6.12.113";
    nativeBuildInputs = [ "/nix/store/synthetic-native-input" ];
    stdenv.hostPlatform.linuxArch = "x86_64";
  };
  toolchainA = "/nix/store/synthetic-toolchain-a";
  toolchainB = "/nix/store/synthetic-toolchain-b";
  configuredA = livepatchLib.mkConfiguredTarget {
    kernel = mkKernel "a";
    kernelVersion = "6.12.113";
    toolchain = toolchainA;
    zfsBuiltinPkg = null;
  };
  configuredB = livepatchLib.mkConfiguredTarget {
    kernel = mkKernel "a";
    kernelVersion = "6.12.113";
    toolchain = toolchainB;
    zfsBuiltinPkg = null;
  };
  configuredAAgain = livepatchLib.mkConfiguredTarget {
    kernel = mkKernel "a";
    kernelVersion = "6.12.113";
    toolchain = toolchainA;
    zfsBuiltinPkg = null;
  };
  mkConfiguredForConfig =
    identity: values:
    livepatchLib.mkConfiguredTarget {
      kernel = mkKernel identity // {
        config = mkKernelConfig values;
      };
      kernelVersion = "6.12.113";
      toolchain = toolchainA;
      zfsBuiltinPkg = null;
    };
  configuredVersionOnly = mkConfiguredForConfig "version-only" (
    configValues
    // {
      CONFIG_MODVERSIONS = "n";
      CONFIG_MODULE_UNLOAD = "n";
      CONFIG_PREEMPT_BUILD = "n";
      CONFIG_SMP = "n";
    }
  );
  configuredSmpOnly = mkConfiguredForConfig "smp-only" (
    configValues
    // {
      CONFIG_MODVERSIONS = "n";
      CONFIG_MODULE_UNLOAD = "n";
      CONFIG_PREEMPT_BUILD = "n";
    }
  );
  configuredRt = mkConfiguredForConfig "rt" (
    configValues
    // {
      CONFIG_PREEMPT_BUILD = "n";
      CONFIG_PREEMPT_RT = "y";
    }
  );
  configuredSparse = mkConfiguredForConfig "sparse" (
    configValues
    // {
      CONFIG_PREEMPT_BUILD = "n";
      CONFIG_PREEMPT_RT = "n";
    }
  );
  configuredVermagics = map (configured: configured.targetBuild.vermagic) [
    configuredVersionOnly
    configuredSmpOnly
    configuredA
    configuredRt
    configuredSparse
  ];
  canonicalVermagic = value: builtins.match "[^[:space:]]+( [^[:space:]]+)*" value != null;
  target = configuredA.kernelTarget;
  targetB = configuredB.kernelTarget;

  builder = {
    kpatchBuild = "/nix/store/synthetic-kpatch-build";
    kpatchRevision = "bea635fbbeb11c5f0f5c0d4ffce34c2e9d2e8a6a";
  };
  qualificationPlanner = import ../../../livepatches/qualification.nix { inherit lib; };
  emptyCatalog = livepatchLib.discoverCatalog ./fixtures/catalog-empty;
  catalog = livepatchLib.discoverCatalog ./fixtures/catalog;
  catalogUnit = builtins.head catalog;
  catalogQualificationChanged = [
    (
      catalogUnit
      // {
        qualification = catalogUnit.qualification // {
          requiredGenericProfiles = [ "set/changed-profile" ];
          oracles = map (
            manifest:
            manifest
            // {
              oracles = map (oracle: oracle // { note = "qualification-only change"; }) manifest.oracles;
            }
          ) catalogUnit.qualification.oracles;
        };
      }
    )
  ];
  normalizedCatalog = livepatchLib.normalizeCatalog {
    inherit builder catalog target;
  };
  normalizedCatalogQualificationChanged = livepatchLib.normalizeCatalog {
    inherit builder target;
    catalog = catalogQualificationChanged;
  };
  qualificationCatalog = map (
    unit:
    unit
    // {
      qualification = unit.qualification // {
        requiredGenericProfiles = [
          "set/vendor-busy-held-transition"
          "set/vendor-failure-recovery"
          "set/vendor-lifecycle"
        ];
        platforms = {
          amd.runnerClass = "amd-livepatch";
          intel.runnerClass = "intel-kvm";
        };
        oracles = map (
          manifest:
          manifest
          // {
            oracles = map (
              oracle:
              oracle
              // {
                applicablePlatforms = [
                  "amd"
                  "intel"
                ];
                expectedOutcome = "success";
                role = "synthetic";
                scope = "fix";
                testAdapter = "os/livepatches/batches/6.12.113.1/qualification/helpers/synthetic.nix";
                timeoutClass = "oracle";
                validator = "os/livepatches/batches/6.12.113.1/qualification/validators/synthetic.sh";
              }
            ) manifest.oracles;
          }
        ) unit.qualification.oracles;
      };
    }
  ) catalog;
  catalogBatch = (builtins.head normalizedCatalog).batch;
  catalogBatchQualificationChanged = (builtins.head normalizedCatalogQualificationChanged).batch;
  emptyQualificationPlan = qualificationPlanner {
    inherit builder target;
    catalog = emptyCatalog;
  };
  qualificationPlan = qualificationPlanner {
    inherit builder catalog target;
  };
  qualificationCoveragePlan = qualificationPlanner {
    inherit builder target;
    catalog = qualificationCatalog;
    plan = true;
    producerAttrs."6.12.113.1" = "synthetic-producer";
  };
  projectCatalog = import ../../../livepatches/batches { inherit lib; };
  normalizedProjectCatalog = livepatchLib.normalizeCatalog {
    inherit builder target;
    catalog = projectCatalog;
  };
  projectQualificationPlan = qualificationPlanner {
    inherit builder target;
    catalog = projectCatalog;
    plan = true;
    producerAttrs = builtins.listToAttrs (
      map (unit: {
        name = unit.batch.release;
        value = "synthetic-producer-${unit.batch.release}";
      }) projectCatalog
    );
  };
  realKernelDefinition =
    if pkgs == null then
      null
    else
      (import ../../linux/available-kernels.nix { inherit lib; }).kernels."6.12.113";
  realKernel =
    if pkgs == null then
      null
    else
      pkgs.callPackage ../../linux {
        kernelVersion = "6.12.113";
        url = "https://github.com/vpsfreecz/linux/archive/${realKernelDefinition.rev}.tar.gz";
        sha256 = realKernelDefinition.sha256;
        structuredExtraConfig = realKernelDefinition.structuredExtraConfig or { };
        features = realKernelDefinition.features or { };
      };
  realOverriddenKernel =
    if pkgs == null then
      null
    else
      pkgs.callPackage ../../linux {
        kernelVersion = "6.12.113";
        url = "https://github.com/vpsfreecz/linux/archive/${realKernelDefinition.rev}.tar.gz";
        sha256 = realKernelDefinition.sha256;
        structuredExtraConfig = {
          PREEMPT_RT = lib.kernel.yes;
        };
        features = realKernelDefinition.features or { };
      };
  realConfigured =
    if pkgs == null then
      null
    else
      livepatchLib.mkConfiguredTarget {
        kernel = realKernel;
        kernelVersion = "6.12.113";
        toolchain = realKernel.stdenv.cc;
        zfsBuiltinPkg = null;
      };
  realConfigFacts =
    if pkgs == null then
      { }
    else
      builtins.listToAttrs (
        map
          (name: {
            inherit name;
            value = realKernel.config."CONFIG_${name}";
          })
          [
            "GCC_PLUGIN_RANDSTRUCT"
            "MODVERSIONS"
            "MODULE_SIG_FORCE"
            "MODULE_UNLOAD"
            "PREEMPT_BUILD"
            "PREEMPT_RT"
            "RANDSTRUCT_FULL"
            "RANDSTRUCT_PERFORMANCE"
            "SMP"
          ]
      );
  realNormalized =
    if pkgs == null then
      null
    else
      builtins.head (
        livepatchLib.normalizeBatches {
          inherit builder;
          descriptors = [ rootA ];
          target = realConfigured.kernelTarget;
        }
      );

  functionA = {
    object = "vmlinux";
    symbol = "function_a";
    sympos = 0;
  };
  functionB = {
    object = "vmlinux";
    symbol = "function_b";
    sympos = 0;
  };
  functionN = {
    object = "vmlinux";
    symbol = "function_n";
    sympos = 0;
  };

  runtime = {
    bootAutoload = false;
    prevention = "synthetic prevention";
    removal = "synthetic removal";
    recovery = "synthetic recovery";
  };

  provenance = {
    source = {
      repository = "vpsfreecz/linux";
      commit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    };
    status = "downstream-only";
    upstream = null;
    stable = null;
  };

  mkFix = id: patchIds: functions: oracleIds: {
    inherit
      functions
      id
      oracleIds
      patchIds
      provenance
      ;
    cves = [ ];
    prerequisites = [ ];
  };

  mkBuild = functions: {
    targets = [ "vmlinux" ];
    expected = {
      callbacks = [ ];
      inherit functions;
      imports = [ ];
      relocations = [ ];
      states = [ ];
    };
  };

  mkPatch = id: path: fixIds: {
    inherit id path fixIds;
  };

  rootA = {
    release = "6.12.113.1";
    kernelVersion = "6.12.113";
    payloadRevision = 1;
    mode = "additive";
    build = mkBuild [ functionA ];
    fixes = [ (mkFix "fix-a" [ "patch-a" ] [ functionA ] [ "oracle-a" ]) ];
    patches = [ (mkPatch "patch-a" ./fixtures/a.patch [ "fix-a" ]) ];
    lineage = {
      predecessorBatch = null;
      functions = [ ];
      states = [ ];
    };
    inherit runtime;
  };

  multiFixOracleBatch = rootA // {
    build = mkBuild [
      functionA
      functionB
    ];
    fixes = [
      (mkFix "fix-a" [ "patch-a" ]
        [ functionA ]
        [
          "oracle-shared"
          "oracle-z"
        ]
      )
      (mkFix "fix-b" [ "patch-b" ]
        [ functionB ]
        [
          "oracle-a"
          "oracle-shared"
        ]
      )
    ];
    patches = [
      (mkPatch "patch-a" ./fixtures/a.patch [ "fix-a" ])
      (mkPatch "patch-b" ./fixtures/b.patch [ "fix-b" ])
    ];
  };
  reorderedMultiFixOracleBatch = multiFixOracleBatch // {
    fixes = lib.reverseList multiFixOracleBatch.fixes;
  };
  emptyOracleBatch = multiFixOracleBatch // {
    fixes = [
      (mkFix "fix-a" [ "patch-a" ] [ functionA ] [ ])
      (mkFix "fix-b" [ "patch-b" ] [ functionB ] [ ])
    ];
  };
  authoredBatchOracleIds = rootA // {
    oracleIds = [ "oracle-a" ];
  };

  neighborN = {
    release = "6.12.113.2";
    kernelVersion = "6.12.113";
    payloadRevision = 1;
    mode = "additive";
    build = mkBuild [ functionN ];
    fixes = [ (mkFix "fix-n" [ "patch-n" ] [ functionN ] [ "oracle-n" ]) ];
    patches = [ (mkPatch "patch-n" ./fixtures/n.patch [ "fix-n" ]) ];
    lineage = {
      predecessorBatch = {
        release = rootA.release;
        payloadRevision = rootA.payloadRevision;
      };
      functions = [ ];
      states = [ ];
    };
    inherit runtime;
  };

  successorB = {
    release = "6.12.113.3";
    kernelVersion = "6.12.113";
    payloadRevision = 1;
    mode = "additive";
    build = mkBuild [
      functionA
      functionB
    ];
    fixes = [ (mkFix "fix-b" [ "patch-b" ] [ functionA functionB ] [ "oracle-b" ]) ];
    patches = [ (mkPatch "patch-b" ./fixtures/b.patch [ "fix-b" ]) ];
    lineage = {
      predecessorBatch = {
        release = neighborN.release;
        payloadRevision = neighborN.payloadRevision;
      };
      functions = [
        (
          functionA
          // {
            predecessorOwner = {
              release = rootA.release;
              payloadRevision = rootA.payloadRevision;
            };
          }
        )
      ];
      states = [ ];
    };
    inherit runtime;
  };

  successorB2 = successorB // {
    release = "6.12.113.2";
    lineage = successorB.lineage // {
      predecessorBatch = {
        release = rootA.release;
        payloadRevision = rootA.payloadRevision;
      };
    };
  };

  normalizeFor =
    selectedTarget: descriptors:
    livepatchLib.normalizeBatches {
      inherit builder descriptors;
      target = selectedTarget;
    };
  normalize = normalizeFor target;

  rootOnly = normalize [ rootA ];
  rootOnlyAgain = normalize [ rootA ];
  rootRevision2 = normalize [ (rootA // { payloadRevision = 2; }) ];
  rootTargetB = normalizeFor targetB [ rootA ];
  complete = normalize [
    rootA
    neighborN
    successorB
  ];
  overlapPair = normalize [
    rootA
    successorB2
  ];
  normalizedRootOnly = builtins.elemAt rootOnly 0;
  normalizedRootOnlyAgain = builtins.elemAt rootOnlyAgain 0;
  normalizedRootTargetB = builtins.elemAt rootTargetB 0;
  normalizedRootRevision2 = builtins.elemAt rootRevision2 0;
  normalizedRoot = builtins.elemAt complete 0;
  normalizedNeighbor = builtins.elemAt complete 1;
  normalizedSuccessor = builtins.elemAt complete 2;
  normalizedOverlapSuccessor = builtins.elemAt overlapPair 1;
  normalizedMultiFixOracleBatch = builtins.head (normalize [ multiFixOracleBatch ]);
  normalizedReorderedMultiFixOracleBatch = builtins.head (normalize [ reorderedMultiFixOracleBatch ]);
  normalizedEmptyOracleBatch = builtins.head (normalize [ emptyOracleBatch ]);
  successorAFunction = builtins.elemAt normalizedSuccessor.build.expected.functions 0;

  contextKpatchBuild =
    if pkgs == null then
      null
    else
      pkgs.runCommand "synthetic-kpatch-build-input" { } ''
        mkdir -p "$out"
      '';
  contextBuilder = builder // {
    kpatchBuild = if pkgs == null then builder.kpatchBuild else toString contextKpatchBuild;
  };
  contextRootA = lib.recursiveUpdate rootA {
    patches = [ (mkPatch "patch-a" ./fixtures/input-context-a/payload.patch [ "fix-a" ]) ];
  };
  contextRootB = lib.recursiveUpdate rootA {
    patches = [ (mkPatch "patch-a" ./fixtures/input-context-b/payload.patch [ "fix-a" ]) ];
  };
  normalizeContext =
    descriptor:
    builtins.head (
      livepatchLib.normalizeBatches {
        builder = contextBuilder;
        descriptors = [ descriptor ];
        inherit target;
      }
    );
  normalizedContextA = normalizeContext contextRootA;
  normalizedContextB = normalizeContext contextRootB;
  contextTargetBuild = configuredA.targetBuild // {
    nativeBuildInputs = [ ];
  };
  mkContextModule =
    batch:
    if pkgs == null then
      null
    else
      (pkgs.callPackage ../default.nix { }) {
        inherit batch;
        kpatchBuild = contextKpatchBuild;
        targetBuild = contextTargetBuild;
      };
  contextModuleA = mkContextModule normalizedContextA;
  contextModuleB = mkContextModule normalizedContextB;
  catalogContextBatch =
    (builtins.head (
      livepatchLib.normalizeCatalog {
        builder = contextBuilder;
        inherit catalog target;
      }
    )).batch;
  catalogContextQualificationChangedBatch =
    (builtins.head (
      livepatchLib.normalizeCatalog {
        builder = contextBuilder;
        catalog = catalogQualificationChanged;
        inherit target;
      }
    )).batch;
  catalogContextModule = mkContextModule catalogContextBatch;
  catalogContextModuleWithoutOracleIds = mkContextModule (
    removeAttrs catalogContextBatch [ "oracleIds" ]
  );
  catalogContextQualificationChangedModule = mkContextModule catalogContextQualificationChangedBatch;
  contextPayloadInput = builtins.path {
    path = ./fixtures/input-context-a/payload.patch;
    name = "vpsadminos-livepatch-payload-0.patch";
  };
  contextFrameworkInput = builtins.path {
    path = ../../../livepatches/framework/release-level.patch;
    name = "vpsadminos-livepatch-release-level.patch";
  };
  contextInspectorInput = builtins.path {
    path = ../inspect.py;
    name = "vpsadminos-livepatch-inspect.py";
  };
  contextContainsPath =
    context: path:
    let
      key = builtins.unsafeDiscardStringContext (toString path);
    in
    builtins.hasAttr key context && ((builtins.getAttr key context).path or false);
  contextBuildInputs =
    if pkgs == null then { } else builtins.getContext contextModuleA.drvAttrs.buildPhase;
  contextCheckInputs =
    if pkgs == null then { } else builtins.getContext contextModuleA.drvAttrs.checkPhase;

  preparationSymvers = "0x00000001\tsynthetic_symbol\tvmlinux\tEXPORT_SYMBOL\t\n";
  preparationModuleLds = ''
    SECTIONS {
      /DISCARD/ : { *(.discard) }
    }
  '';
  preparationSource =
    if pkgs == null then
      null
    else
      pkgs.runCommand "synthetic-livepatch-kernel-source.tar.gz"
        {
          nativeBuildInputs = [
            pkgs.gnutar
            pkgs.gzip
          ];
        }
        ''
          mkdir -p tree/kernel-source/include/linux tree/kernel-source/scripts
          touch tree/kernel-source/Makefile
          touch tree/kernel-source/scripts/link-vmlinux.sh
          touch tree/kernel-source/scripts/Makefile.modfinal
          tar czf "$out" -C tree kernel-source
        '';
  preparationConfig =
    if pkgs == null then
      null
    else
      pkgs.writeText "synthetic-livepatch-kernel.config" ''
        CONFIG_DEBUG_INFO=y
        CONFIG_DEBUG_INFO_BTF=y
        CONFIG_LIVEPATCH=y
        CONFIG_MODVERSIONS=y
      '';
  preparationKernelOut =
    if pkgs == null then
      null
    else
      pkgs.runCommand "synthetic-livepatch-kernel" { } ''
        mkdir -p "$out"
      '';
  preparationToolchain =
    if pkgs == null then
      null
    else
      pkgs.runCommand "synthetic-livepatch-toolchain" { } ''
        mkdir -p "$out/bin"
      '';
  preparationKpatchBuild =
    if pkgs == null then
      null
    else
      pkgs.runCommand "synthetic-livepatch-kpatch-build" { } ''
        mkdir -p "$out/kpatch-build" "$out/kmod/patch"
        printf %s ${lib.escapeShellArg preparationSymvers} > "$out/expected-Module.symvers"
        for required in \
          kpatch-cc \
          create-diff-object \
          create-klp-module; do
          touch "$out/kpatch-build/$required"
        done
        for required in \
          Makefile \
          kpatch.lds.S \
          patch-hook.c \
          kpatch-patch-hook.c \
          livepatch-patch-hook.c \
          kpatch-patch.h \
          kpatch-macros.h \
          kpatch-syscall.h; do
          touch "$out/kmod/patch/$required"
        done
        cat > "$out/kpatch-build/kpatch-build" <<'EOF'
        #!/bin/sh
        set -eu
        source_root=
        module_name=
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -s)
              source_root="$2"
              shift 2
              ;;
            -n)
              module_name="$2"
              shift 2
              ;;
            -v|-t)
              shift 2
              ;;
            --non-replace)
              shift
              ;;
            *)
              shift
              ;;
          esac
        done
        test -n "$source_root"
        test -n "$module_name"
        cmp -s "$source_root/Module.symvers" "$(dirname "$0")/../expected-Module.symvers"
        mkdir -p "$TEMPDIR"
        printf '%s\n' kernel/bpf/core.o > "$TEMPDIR/changed_objs"
        touch "$module_name.ko"
        EOF
        chmod +x "$out/kpatch-build/kpatch-build"
      '';
  preparationFailingKpatchBuild =
    if pkgs == null then
      null
    else
      pkgs.runCommand "synthetic-livepatch-kpatch-build-failing" { } ''
        cp -r ${preparationKpatchBuild}/. "$out/"
        chmod -R u+w "$out"
        cat > "$out/kpatch-build/kpatch-build" <<'EOF'
        #!/bin/sh
        echo "synthetic kpatch failure" >&2
        exit 42
        EOF
        chmod +x "$out/kpatch-build/kpatch-build"
      '';
  mkPreparationCase =
    name: symvers: moduleLds: kpatchBuild:
    if pkgs == null then
      null
    else
      let
        dev = pkgs.runCommand "synthetic-livepatch-kernel-${name}-dev" { } (
          ''
            mkdir -p "$out/lib/modules/6.12.113/build/scripts"
            printf 'Linux version 6.12.113 synthetic\n' > "$out/vmlinux"
          ''
          + lib.optionalString (symvers != null) ''
            printf %s ${lib.escapeShellArg symvers} > "$out/lib/modules/6.12.113/build/Module.symvers"
          ''
          + lib.optionalString (moduleLds != null) ''
            printf %s ${lib.escapeShellArg moduleLds} > "$out/lib/modules/6.12.113/build/scripts/module.lds"
          ''
        );
        kernel = {
          outPath = preparationKernelOut;
          inherit dev;
          src = preparationSource;
          configfile = preparationConfig;
          config = kernelConfig;
          modDirVersion = "6.12.113";
          nativeBuildInputs = [
            pkgs.gnutar
            pkgs.gzip
          ];
          stdenv.hostPlatform.linuxArch = "x86_64";
        };
        configured = livepatchLib.mkConfiguredTarget {
          inherit kernel;
          kernelVersion = "6.12.113";
          toolchain = preparationToolchain;
          zfsBuiltinPkg = null;
        };
        batch = builtins.head (
          livepatchLib.normalizeBatches {
            builder = builder // {
              kpatchBuild = toString kpatchBuild;
            };
            descriptors = [ rootA ];
            target = configured.kernelTarget;
          }
        );
        module = (pkgs.callPackage ../default.nix { }) {
          inherit batch kpatchBuild;
          targetBuild = configured.targetBuild;
        };
        fixture = module.overrideAttrs (_: {
          doCheck = false;
          installPhase = ''
            mkdir -p "$out/scripts"
            cp src/Module.symvers "$out/Module.symvers"
            cp src/scripts/module.lds "$out/scripts/module.lds"
          '';
        });
      in
      {
        inherit
          batch
          configured
          dev
          fixture
          module
          ;
      };
  preparationGood =
    mkPreparationCase "good" preparationSymvers preparationModuleLds
      preparationKpatchBuild;
  preparationMissing = mkPreparationCase "missing" null preparationModuleLds preparationKpatchBuild;
  preparationMissingModuleLds =
    mkPreparationCase "missing-module-lds" preparationSymvers null
      preparationKpatchBuild;
  preparationWrong =
    mkPreparationCase "wrong" "0x00000001\tsynthetic_symbol\twrong-module\tEXPORT_SYMBOL\t\n"
      preparationModuleLds
      preparationKpatchBuild;
  preparationKpatchFailure =
    mkPreparationCase "kpatch-failure" preparationSymvers preparationModuleLds
      preparationFailingKpatchBuild;
  preparationBuildInputs =
    if pkgs == null then { } else builtins.getContext preparationGood.module.drvAttrs.buildPhase;
  preparationDevDrvPath =
    if pkgs == null then null else builtins.unsafeDiscardStringContext preparationGood.dev.drvPath;
  preparationPayloadInput = builtins.path {
    path = ./fixtures/a.patch;
    name = "vpsadminos-livepatch-payload-0.patch";
  };
  preparationBuildPathInputs =
    if pkgs == null then
      [ ]
    else
      lib.sort builtins.lessThan (
        builtins.filter (name: (builtins.getAttr name preparationBuildInputs).path or false) (
          builtins.attrNames preparationBuildInputs
        )
      );
  preparationExpectedBuildPathInputs = lib.sort builtins.lessThan (
    map (path: builtins.unsafeDiscardStringContext (toString path)) [
      preparationPayloadInput
      contextFrameworkInput
    ]
  );

  evaluationFails = value: !(builtins.tryEval (builtins.deepSeq value true)).success;

  catalogReleaseDirectory = ./fixtures/catalog/6.12.113.1;
  validateCatalogUnit =
    unit:
    livepatchLib.validateBatchUnit {
      directory = catalogReleaseDirectory;
      directoryName = "6.12.113.1";
      inherit unit;
    };
  missingSeriesUnit = lib.recursiveUpdate catalogUnit {
    batch.patches = [ (builtins.head catalogUnit.batch.patches) ];
  };
  duplicateSeriesUnit = lib.recursiveUpdate catalogUnit {
    batch.patches = catalogUnit.batch.patches ++ [ (builtins.head catalogUnit.batch.patches) ];
  };
  wrongSeriesOwnershipUnit = lib.recursiveUpdate catalogUnit {
    batch.patches = [
      ((builtins.head catalogUnit.batch.patches) // { fixIds = [ "fix-a" ]; })
      (builtins.elemAt catalogUnit.batch.patches 1)
    ];
  };
  missingOracleManifest = [ (builtins.head catalogUnit.qualification.oracles) ];
  wrongOracleManifest = map (
    manifest:
    if manifest.fixId == "fix-b" then
      manifest // { oracles = [ { id = "wrong-oracle"; } ]; }
    else
      manifest
  ) catalogUnit.qualification.oracles;
  undeclaredSharedOwnership = catalogUnit.batch // {
    patches = [
      ((builtins.head catalogUnit.batch.patches) // { fixIds = [ "fix-a" ]; })
      (builtins.elemAt catalogUnit.batch.patches 1)
    ];
  };

  independentOverlap = neighborN // {
    build = mkBuild [ functionA ];
    fixes = [ (mkFix "fix-n" [ "patch-n" ] [ functionA ] [ "oracle-n" ]) ];
  };
  incompleteProvenance = rootA // {
    fixes = [
      (
        (mkFix "fix-a" [ "patch-a" ] [ functionA ] [ "oracle-a" ])
        // {
          provenance = removeAttrs provenance [ "stable" ];
        }
      )
    ];
  };
  stableKnownAbsentUpstream = lib.recursiveUpdate rootA {
    fixes = [
      (
        (mkFix "fix-a" [ "patch-a" ] [ functionA ] [ "oracle-a" ])
        // {
          provenance = provenance // {
            status = "stable";
            stable = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
            upstream = null;
          };
        }
      )
    ];
  };
  callbackBatch = lib.recursiveUpdate rootA {
    build.expected.callbacks = [ "pre_patch" ];
  };
  stateBatch = lib.recursiveUpdate rootA {
    lineage.states = [
      {
        id = 1;
        fromVersion = 1;
        toVersion = 1;
        predecessorOwner = {
          release = rootA.release;
          payloadRevision = rootA.payloadRevision;
        };
      }
    ];
  };
  payloadStateBatch = lib.recursiveUpdate rootA {
    build.expected.states = [ { id = "0x1"; } ];
  };
  shadowBatch = lib.recursiveUpdate rootA {
    build.expected.imports = [ "klp_shadow_get" ];
  };
  missingPredecessor = lib.recursiveUpdate successorB {
    lineage.predecessorBatch.release = "6.12.113.9";
  };
  branchMiddleB = lib.recursiveUpdate successorB {
    release = "6.12.113.2";
    build = mkBuild [ functionB ];
    fixes = [ (mkFix "fix-b" [ "patch-b" ] [ functionB ] [ "oracle-b" ]) ];
    lineage.predecessorBatch = {
      release = rootA.release;
      payloadRevision = rootA.payloadRevision;
    };
    lineage.functions = [ ];
  };
  mkBranchCandidate = releaseOrdinal: predecessorBatch: {
    release = "6.12.113.${toString releaseOrdinal}";
    kernelVersion = "6.12.113";
    payloadRevision = 1;
    mode = "additive";
    build = mkBuild [ functionA ];
    fixes = [ (mkFix "fix-c" [ "patch-b" ] [ functionA ] [ "oracle-c" ]) ];
    patches = [ (mkPatch "patch-b" ./fixtures/b.patch [ "fix-c" ]) ];
    lineage = {
      inherit predecessorBatch;
      functions = [
        (
          functionA
          // {
            predecessorOwner = {
              release = rootA.release;
              payloadRevision = rootA.payloadRevision;
            };
          }
        )
      ];
      states = [ ];
    };
    inherit runtime;
  };
  branchCandidateC = mkBranchCandidate 2 {
    release = rootA.release;
    payloadRevision = rootA.payloadRevision;
  };
  linearCandidateC = mkBranchCandidate 3 {
    release = branchMiddleB.release;
    payloadRevision = branchMiddleB.payloadRevision;
  };
  normalizedLinear = normalize [
    rootA
    branchMiddleB
    linearCandidateC
  ];
  normalizedLinearCandidate = builtins.elemAt normalizedLinear 2;
  normalizedStableKnownAbsentUpstream = builtins.elemAt (normalize [ stableKnownAbsentUpstream ]) 0;
  authoredProtocol = rootA // {
    unameLevel.protocol = "unknown";
  };
  zeroOrdinal = lib.recursiveUpdate rootA {
    release = "6.12.113.0";
  };
  negativeOrdinal = lib.recursiveUpdate rootA {
    release = "6.12.113.-1";
  };
  nonIntegerOrdinal = lib.recursiveUpdate rootA {
    release = "6.12.113.one";
  };
  gapRoot = lib.recursiveUpdate rootA {
    release = "6.12.113.2";
  };
  gapSuccessor = lib.recursiveUpdate successorB {
    release = "6.12.113.4";
  };
  duplicateOrdinal = lib.recursiveUpdate neighborN {
    release = "6.12.113.1";
  };
  longReleaseTarget = lib.recursiveUpdate target {
    id = "synthetic-long-release";
    kernelVersion = "12345678901234567890123456789012.12345678901234567890123456789012";
  };
  mismatchedVersion = rootA // {
    kernelVersion = "6.12.112";
  };
  authoredTarget = rootA // {
    kernelTarget = target.id;
  };
  badConfiguredKernel = mkKernel "bad" // {
    config = mkKernelConfig (removeAttrs configValues [ "CONFIG_MODVERSIONS" ]);
  };
  forcedSignatureKernel = mkKernel "forced-signature" // {
    config = mkKernelConfig (configValues // { CONFIG_MODULE_SIG_FORCE = "y"; });
  };
  randstructKernel = mkKernel "randstruct" // {
    config = mkKernelConfig (configValues // { CONFIG_RANDSTRUCT_FULL = "y"; });
  };
  invalidConfigValueKernel = mkKernel "invalid-config-value" // {
    config = mkKernelConfig (configValues // { CONFIG_SMP = "m"; });
  };
  wrongConfigNameKernel = mkKernel "wrong-config-name" // {
    config = mkKernelConfig (
      (removeAttrs configValues [ "CONFIG_MODVERSIONS" ]) // { CONFIG_MODVERSION = "y"; }
    );
  };
  unsupportedPlatformKernel = mkKernel "unsupported-platform" // {
    stdenv.hostPlatform.linuxArch = "aarch64";
  };
  pluginRandstructKernel = mkKernel "plugin-randstruct" // {
    config = mkKernelConfig (configValues // { CONFIG_GCC_PLUGIN_RANDSTRUCT = "y"; });
  };
  configuredTargetFails = args: evaluationFails (livepatchLib.mkConfiguredTarget args);
  mismatchedPackage =
    if pkgs == null then
      null
    else
      (pkgs.callPackage ../default.nix { }) {
        batch = normalizedRootOnly;
        kpatchBuild = builder.kpatchBuild;
        targetBuild = configuredB.targetBuild;
      };
in

assert emptyCatalog == [ ];
assert emptyQualificationPlan.selectedSets == 0;
assert qualificationPlan.selectedSets == 1;
assert builtins.length qualificationPlan.releases == 1;
assert
  (builtins.head qualificationCoveragePlan.sets).oracleIds == [
    "oracle-a"
    "oracle-b"
  ];
assert
  ((builtins.head (builtins.head qualificationCoveragePlan.sets).members).oracleIds)
  == catalogBatch.oracleIds;
assert
  builtins.concatMap (set: map (member: member.oracleIds) set.members) projectQualificationPlan.sets
  == map (entry: entry.batch.oracleIds) normalizedProjectCatalog;
assert builtins.length catalogUnit.batch.fixes == 2;
assert
  map (patch: patch.id) catalogUnit.batch.patches == [
    "shared-prerequisite"
    "fix-b-change"
  ];
assert
  (builtins.head catalogUnit.batch.patches).fixIds == [
    "fix-a"
    "fix-b"
  ];
assert
  map (manifest: manifest.fixId) catalogUnit.qualification.oracles == [
    "fix-a"
    "fix-b"
  ];
assert catalogBatch.release == "6.12.113.1";
assert catalogBatch.releaseOrdinal == 1;
assert
  catalogBatch.oracleIds == [
    "oracle-a"
    "oracle-b"
  ];
assert catalogBatch.oracleIds == catalogBatchQualificationChanged.oracleIds;
assert !(catalogBatch.manifest ? oracleIds);
assert catalogBatch.moduleName == "lp_612113_1_${builtins.substring 0 12 catalogBatch.inputDigest}";
assert
  catalogBatch.manifest.patches
  == map (patch: removeAttrs patch [ "path" ]) catalogBatch.build.patches;
assert catalogBatch.manifest.targets == [ "vmlinux" ];
assert catalogBatch.manifest == catalogBatchQualificationChanged.manifest;
assert catalogBatch.producerDigest == catalogBatchQualificationChanged.producerDigest;
assert catalogBatch.inputDigest == catalogBatchQualificationChanged.inputDigest;
assert catalogBatch.moduleName == catalogBatchQualificationChanged.moduleName;
assert evaluationFails (livepatchLib.discoverFixes ./fixtures/fix-id-mismatch);
assert evaluationFails (validateCatalogUnit missingSeriesUnit);
assert evaluationFails (validateCatalogUnit duplicateSeriesUnit);
assert evaluationFails (validateCatalogUnit wrongSeriesOwnershipUnit);
assert evaluationFails (normalize [ undeclaredSharedOwnership ]);
assert evaluationFails (
  livepatchLib.validateOracleClosure "synthetic" catalogUnit.batch.fixes missingOracleManifest
);
assert evaluationFails (
  livepatchLib.validateOracleClosure "synthetic" catalogUnit.batch.fixes wrongOracleManifest
);
assert normalize [ ] == [ ];
assert
  normalizedMultiFixOracleBatch.oracleIds == [
    "oracle-a"
    "oracle-shared"
    "oracle-z"
  ];
assert normalizedReorderedMultiFixOracleBatch.oracleIds == normalizedMultiFixOracleBatch.oracleIds;
assert normalizedEmptyOracleBatch.oracleIds == [ ];
assert evaluationFails (normalize [ authoredBatchOracleIds ]);
assert normalizedRootOnly.manifest == normalizedRoot.manifest;
assert normalizedRootOnly.moduleName == normalizedRoot.moduleName;
assert normalizedRootOnly.manifest == normalizedRootOnlyAgain.manifest;
assert normalizedRootOnly.producerDigest == normalizedRootOnlyAgain.producerDigest;
assert normalizedRootOnly.inputDigest == normalizedRootOnlyAgain.inputDigest;
assert normalizedRootOnly.moduleName == normalizedRootOnlyAgain.moduleName;
assert normalizedContextA.producerDigest == normalizedContextB.producerDigest;
assert normalizedContextA.inputDigest == normalizedContextB.inputDigest;
assert normalizedContextA.moduleName == normalizedContextB.moduleName;
assert normalizedContextA.manifest == normalizedContextB.manifest;
assert pkgs == null || contextModuleA.drvPath == contextModuleB.drvPath;
assert pkgs == null || contextModuleA.outPath == contextModuleB.outPath;
assert
  pkgs == null || catalogContextModule.drvPath == catalogContextQualificationChangedModule.drvPath;
assert
  pkgs == null || catalogContextModule.outPath == catalogContextQualificationChangedModule.outPath;
assert pkgs == null || catalogContextModule.drvPath == catalogContextModuleWithoutOracleIds.drvPath;
assert pkgs == null || catalogContextModule.outPath == catalogContextModuleWithoutOracleIds.outPath;
assert pkgs == null || contextContainsPath contextBuildInputs contextPayloadInput;
assert pkgs == null || contextContainsPath contextBuildInputs contextFrameworkInput;
assert pkgs == null || contextContainsPath contextCheckInputs contextInspectorInput;
assert pkgs == null || builtins.hasAttr preparationDevDrvPath preparationBuildInputs;
assert
  pkgs == null
  || lib.hasInfix (builtins.unsafeDiscardStringContext preparationGood.configured.targetBuild.identity.moduleSymvers) (
    preparationGood.module.drvAttrs.buildPhase
  );
assert
  pkgs == null
  || lib.hasInfix "${builtins.unsafeDiscardStringContext (toString preparationGood.dev)}/lib/modules/6.12.113/build/scripts/module.lds" preparationGood.module.drvAttrs.buildPhase;
assert pkgs == null || preparationBuildPathInputs == preparationExpectedBuildPathInputs;
assert
  pkgs == null || preparationGood.batch.kernelTarget == preparationGood.configured.kernelTarget;
assert normalizedRootOnly.unameLevel.releaseOrdinal == 1;
assert normalizedRootOnly.unameLevel.protocol == "vpsadminos-additive-uname-v1";
assert normalizedRootOnly.unameLevel.predecessorOrdinal == null;
assert normalizedRootOnly.unameLevel.publishedRelease == "6.12.113.1";
assert normalizedRootOnly.unameLevel.rollbackRelease == "6.12.113";
assert
  normalizedRootOnly.unameLevel.frameworkPatchSha256
  == "46c9e631d4c8a767e32d49e3ee1e8cef7ca43f926628cd9c817e7fd47983a597";
assert builtins.stringLength normalizedRootOnly.unameLevel.generatedHeaderSha256 == 64;
assert
  normalizedRootOnly.moduleName
  == "lp_612113_1_${builtins.substring 0 12 normalizedRootOnly.inputDigest}";
assert normalizedRootOnly.build.expected.callbacks == normalizedRootOnly.unameLevel.callbacks;
assert
  normalizedRootOnly.build.expected.states == [
    {
      id = "0x48573a1786d6fe85";
      version = 1;
      data = "0x0000000000000000";
    }
  ];
assert normalizedRootOnly.build.expected.stateSection.recordSize == 24;
assert normalizedRootOnly.build.expected.stateSection.alignment == 8;
assert normalizedRootOnly.build.expected.stateSection.sentinel.zero;
assert
  normalizedRootOnly.unameLevel.publishedRelease
  == normalizedRootRevision2.unameLevel.publishedRelease;
assert normalizedRootOnly.producerDigest != normalizedRootRevision2.producerDigest;
assert normalizedRootOnly.inputDigest != normalizedRootRevision2.inputDigest;
assert normalizedRootOnly.moduleName != normalizedRootRevision2.moduleName;
assert
  normalizedRootOnly.unameLevel.generatedHeaderSha256
  != normalizedRootRevision2.unameLevel.generatedHeaderSha256;
assert normalizedRootOnly.release == normalizedRootTargetB.release;
assert normalizedRootOnly.payloadRevision == normalizedRootTargetB.payloadRevision;
assert normalizedRootOnly.producerDigest != normalizedRootTargetB.producerDigest;
assert normalizedRootOnly.inputDigest != normalizedRootTargetB.inputDigest;
assert normalizedRootOnly.moduleName != normalizedRootTargetB.moduleName;
assert normalizedRootOnly.manifest.kernelTarget.identity == target.identity;
assert normalizedRootTargetB.manifest.kernelTarget.identity == targetB.identity;
assert configuredA == configuredAAgain;
assert target.id != targetB.id;
assert
  builtins.attrNames target.identity == [
    "configFile"
    "kernelDev"
    "kernelOut"
    "kernelSource"
    "moduleSymvers"
    "toolchain"
    "vmlinux"
    "zfsBuiltin"
  ];
assert configuredA.targetBuild.identity == target.identity;
assert configuredVersionOnly.targetBuild.vermagic == "6.12.113";
assert configuredSmpOnly.targetBuild.vermagic == "6.12.113 SMP";
assert configuredA.targetBuild.vermagic == "6.12.113 SMP preempt mod_unload modversions";
assert configuredRt.targetBuild.vermagic == "6.12.113 SMP preempt_rt mod_unload modversions";
assert configuredSparse.targetBuild.vermagic == "6.12.113 SMP mod_unload modversions";
assert builtins.all canonicalVermagic configuredVermagics;
assert configuredA.targetBuild.signature == target.signature;
assert pkgs == null || realConfigured.targetBuild.identity.kernelOut == realKernel.outPath;
assert pkgs == null || realConfigured.targetBuild.identity.kernelDev == realKernel.dev.outPath;
assert
  pkgs == null || realConfigured.targetBuild.identity.configFile == realKernel.configfile.outPath;
assert pkgs == null || realConfigured.targetBuild.identity.kernelSource == toString realKernel.src;
assert pkgs == null || lib.hasInfix realKernelDefinition.rev (toString realKernel.src);
assert
  pkgs == null || realConfigured.targetBuild.identity.vmlinux == "${realKernel.dev.outPath}/vmlinux";
assert
  pkgs == null
  ||
    realConfigured.targetBuild.identity.moduleSymvers
    == "${realKernel.dev.outPath}/lib/modules/${realKernel.modDirVersion}/build/Module.symvers";
assert pkgs == null || realConfigured.kernelTarget.identity == realConfigured.targetBuild.identity;
assert
  pkgs == null
  || builtins.match "configured-6-12-113-[0-9a-f]{12}" realConfigured.kernelTarget.id != null;
assert
  pkgs == null
  ||
    realConfigFacts == {
      GCC_PLUGIN_RANDSTRUCT = "n";
      MODVERSIONS = "y";
      MODULE_SIG_FORCE = "n";
      MODULE_UNLOAD = "y";
      PREEMPT_BUILD = "y";
      PREEMPT_RT = "n";
      RANDSTRUCT_FULL = "n";
      RANDSTRUCT_PERFORMANCE = "n";
      SMP = "y";
    };
assert
  pkgs == null
  || realConfigured.targetBuild.vermagic == "6.12.113 SMP preempt mod_unload modversions";
assert pkgs == null || realConfigured.targetBuild.signature.required == false;
assert pkgs == null || realConfigured.targetBuild.signature.sigId == null;
assert pkgs == null || realConfigured.targetBuild.signature.sigKey == null;
assert pkgs == null || realConfigured.targetBuild.signature.signer == null;
assert pkgs == null || realNormalized.kernelTarget == realConfigured.kernelTarget;
assert pkgs == null || !realOverriddenKernel.config.isSet "SMP";
assert
  pkgs == null
  || configuredTargetFails {
    kernel = realOverriddenKernel;
    kernelVersion = "6.12.113";
    toolchain = realOverriddenKernel.stdenv.cc;
    zfsBuiltinPkg = null;
  };
assert
  normalizedRootOnly.unameLevel.generatedHeaderSha256
  != normalizedRootTargetB.unameLevel.generatedHeaderSha256;
assert normalizedNeighbor.lineage.depth == 1;
assert normalizedNeighbor.lineage.predecessorBatch.release == rootA.release;
assert normalizedNeighbor.lineage.functions == [ ];
assert normalizedNeighbor.unameLevel.releaseOrdinal == 2;
assert normalizedNeighbor.unameLevel.rollbackRelease == "6.12.113.1";
assert
  normalizedNeighbor.unameLevel.generatedHeaderSha256
  != normalizedRoot.unameLevel.generatedHeaderSha256;
assert normalizedNeighbor.producerDigest != normalizedRoot.producerDigest;
assert normalizedNeighbor.inputDigest != normalizedRoot.inputDigest;
assert normalizedNeighbor.moduleName != normalizedRoot.moduleName;
assert
  (builtins.elemAt normalizedNeighbor.unameLevel.callbacks 0).symbol
  == "vpsadminos_uname_level_p2_pre_patch";
assert normalizedSuccessor.lineage.depth == 2;
assert normalizedSuccessor.lineage.predecessorBatch.release == neighborN.release;
assert normalizedSuccessor.unameLevel.releaseOrdinal == 3;
assert normalizedSuccessor.unameLevel.predecessorOrdinal == 2;
assert normalizedSuccessor.unameLevel.rollbackRelease == "6.12.113.2";
assert
  successorAFunction.semanticFixes == [
    "fix-a"
    "fix-b"
  ];
assert
  successorAFunction.oracleIds == [
    "oracle-a"
    "oracle-b"
  ];
assert !(builtins.elem "fix-n" successorAFunction.semanticFixes);
assert normalizedOverlapSuccessor.lineage.depth == 1;
assert normalizedOverlapSuccessor.lineage.predecessorBatch.release == rootA.release;
assert
  (builtins.head normalizedOverlapSuccessor.build.expected.functions).semanticFixes == [
    "fix-a"
    "fix-b"
  ];
assert (builtins.elemAt normalizedRoot.fixes 0).provenance.status == "downstream-only";
assert (builtins.elemAt normalizedRoot.fixes 0).provenance.upstream == null;
assert (builtins.elemAt normalizedRoot.fixes 0).provenance.stable == null;
assert (builtins.elemAt normalizedStableKnownAbsentUpstream.fixes 0).provenance.upstream == null;
assert (builtins.elemAt normalizedStableKnownAbsentUpstream.fixes 0).provenance.status == "stable";
assert normalizedLinearCandidate.lineage.depth == 2;
assert normalizedLinearCandidate.lineage.predecessorBatch.release == branchMiddleB.release;
assert
  (builtins.elemAt normalizedLinearCandidate.lineage.functions 0).predecessorOwner.release
  == rootA.release;
assert evaluationFails (normalize [
  rootA
  independentOverlap
]);
assert evaluationFails (normalize [ incompleteProvenance ]);
assert evaluationFails (normalize [ callbackBatch ]);
assert evaluationFails (normalize [ stateBatch ]);
assert evaluationFails (normalize [ payloadStateBatch ]);
assert evaluationFails (normalize [ shadowBatch ]);
assert evaluationFails (normalize [
  rootA
  missingPredecessor
]);
assert evaluationFails (normalize [
  rootA
  branchMiddleB
  branchCandidateC
]);
assert evaluationFails (normalize [ authoredProtocol ]);
assert evaluationFails (normalize [ zeroOrdinal ]);
assert evaluationFails (normalize [ negativeOrdinal ]);
assert evaluationFails (normalize [ nonIntegerOrdinal ]);
assert evaluationFails (normalize [ gapRoot ]);
assert evaluationFails (normalize [
  rootA
  gapSuccessor
]);
assert evaluationFails (normalize [
  rootA
  duplicateOrdinal
]);
assert
  normalize [
    neighborN
    rootA
  ] == [
    normalizedRoot
    normalizedNeighbor
  ];
assert evaluationFails (normalize [ mismatchedVersion ]);
assert evaluationFails (normalize [ authoredTarget ]);
assert configuredTargetFails {
  kernel = badConfiguredKernel;
  kernelVersion = "6.12.113";
  toolchain = toolchainA;
  zfsBuiltinPkg = null;
};
assert configuredTargetFails {
  kernel = forcedSignatureKernel;
  kernelVersion = "6.12.113";
  toolchain = toolchainA;
  zfsBuiltinPkg = null;
};
assert configuredTargetFails {
  kernel = randstructKernel;
  kernelVersion = "6.12.113";
  toolchain = toolchainA;
  zfsBuiltinPkg = null;
};
assert configuredTargetFails {
  kernel = invalidConfigValueKernel;
  kernelVersion = "6.12.113";
  toolchain = toolchainA;
  zfsBuiltinPkg = null;
};
assert configuredTargetFails {
  kernel = wrongConfigNameKernel;
  kernelVersion = "6.12.113";
  toolchain = toolchainA;
  zfsBuiltinPkg = null;
};
assert configuredTargetFails {
  kernel = unsupportedPlatformKernel;
  kernelVersion = "6.12.113";
  toolchain = toolchainA;
  zfsBuiltinPkg = null;
};
assert configuredTargetFails {
  kernel = pluginRandstructKernel;
  kernelVersion = "6.12.113";
  toolchain = toolchainA;
  zfsBuiltinPkg = null;
};
assert pkgs == null || evaluationFails mismatchedPackage;
assert evaluationFails (
  normalizeFor longReleaseTarget [ (rootA // { kernelVersion = longReleaseTarget.kernelVersion; }) ]
);
{
  rootModule = normalizedRoot.moduleName;
  targetBModule = normalizedRootTargetB.moduleName;
  neighborDepth = normalizedNeighbor.lineage.depth;
  successorDepth = normalizedSuccessor.lineage.depth;
  successorSemanticFixes = successorAFunction.semanticFixes;
  contextModuleDrv = if pkgs == null then null else contextModuleA.drvPath;
  contextInputs =
    if pkgs == null then
      { }
    else
      {
        framework = toString contextFrameworkInput;
        inspector = toString contextInspectorInput;
        payload = toString contextPayloadInput;
      };
  preparation =
    if pkgs == null then
      { }
    else
      {
        expectedModuleSymvers = preparationGood.configured.targetBuild.identity.moduleSymvers;
        expectedModuleLds = "${preparationGood.dev}/lib/modules/6.12.113/build/scripts/module.lds";
        successDrv = preparationGood.fixture.drvPath;
        missingDrv = preparationMissing.fixture.drvPath;
        missingModuleLdsDrv = preparationMissingModuleLds.fixture.drvPath;
        wrongDrv = preparationWrong.fixture.drvPath;
        kpatchFailureDrv = preparationKpatchFailure.fixture.drvPath;
      };
}
