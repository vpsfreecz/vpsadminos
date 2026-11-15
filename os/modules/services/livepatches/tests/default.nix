{
  pkgs ? import (builtins.getFlake (toString ../../../../..)).inputs.nixpkgs {
    config = { };
  },
}:

let
  lib = pkgs.lib;
  livepatchLib = import ../../../../livepatches/lib.nix { inherit lib; };
  testRoot = "/tmp/vpsadminos-livepatch-scalar-test";
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
  kernelConfig = configValues // {
    isSet = name: builtins.hasAttr "CONFIG_${name}" configValues;
    getValue = name: configValues."CONFIG_${name}" or null;
  };
  mkKernel = version: identity: {
    outPath = "/nix/store/synthetic-kernel-${identity}";
    dev = {
      outPath = "/nix/store/synthetic-kernel-${identity}-dev";
    };
    src = "/nix/store/synthetic-kernel-source";
    configfile = "/nix/store/synthetic-kernel-config";
    config = kernelConfig;
    modDirVersion = version;
    nativeBuildInputs = [ "/nix/store/synthetic-native-input" ];
    stdenv = {
      cc = "/nix/store/synthetic-toolchain-${identity}";
      hostPlatform.linuxArch = "x86_64";
    };
  };
  fixtureKernelVersion = "6.12.113";
  rootRelease = "${fixtureKernelVersion}.1";
  successorRelease = "${fixtureKernelVersion}.2";
  gapRelease = "${fixtureKernelVersion}.3";
  unrelatedKernelVersion = "6.12.999";
  unrelatedRelease = "${unrelatedKernelVersion}.1";
  configuredKernel = mkKernel fixtureKernelVersion "a";
  stableKernelOwner = import ../../../../packages/linux/packages.nix {
    config.system.vpsadminos.enableUnstable = false;
    inherit lib pkgs;
  };
  stableKernelVersion = stableKernelOwner.defaultVersion;
  stableKernel = stableKernelOwner.genKernelPackage stableKernelVersion;
  kernel113 = stableKernelOwner.genKernelPackage fixtureKernelVersion;
  livepatchMetadataNames = [
    "SMP"
    "PREEMPT_BUILD"
    "PREEMPT_RT"
    "MODULE_UNLOAD"
    "MODVERSIONS"
    "MODULE_SIG_FORCE"
    "GCC_PLUGIN_RANDSTRUCT"
    "RANDSTRUCT_FULL"
    "RANDSTRUCT_PERFORMANCE"
  ];
  expectedLivepatchMetadata = [
    "y"
    "y"
    "n"
    "y"
    "y"
    "n"
    "n"
    "n"
    "n"
  ];
  missingLivepatchMetadata = map (_name: null) livepatchMetadataNames;
  livepatchMetadata = kernel: map kernel.config.getValue livepatchMetadataNames;
  providerKernel =
    overrides:
    pkgs.callPackage ../../../../packages/linux/generic.nix (
      {
        src = stableKernel.src;
        version = stableKernelVersion;
        modDirVersion = stableKernelVersion;
        features = { };
        structuredExtraConfig = { };
        kernelPatches = [ pkgs.kernelPatches.bridge_stp_helper ];
        postConfigPatches = [ ];
        zfsBuiltinPkg = null;
      }
      // overrides
    );
  non612MetadataKernel = providerKernel {
    version = "6.13.0";
    modDirVersion = "6.13.0";
  };
  wrongArchitectureMetadataKernel = providerKernel {
    kernelArch = "arm64";
  };
  customDefconfigMetadataKernel = providerKernel {
    defconfig = "defconfig";
  };
  legacyOverrideMetadataKernel = providerKernel {
    extraConfig = "CONFIG_DEBUG_INFO y";
  };
  structuredOverrideMetadataKernel = providerKernel {
    structuredExtraConfig.DEBUG_INFO = lib.kernel.yes;
  };
  rtMetadataKernel = providerKernel {
    features.preempt_rt = true;
  };
  configPatchMetadataKernel = providerKernel {
    kernelPatches = [
      pkgs.kernelPatches.bridge_stp_helper
      {
        name = "synthetic-config-changing-patch";
        patch = ../../../../packages/livepatch-module/tests/fixtures/a.patch;
        extraConfig = "CONFIG_DEBUG_INFO y";
      }
    ];
  };
  structuredConfigPatchMetadataKernel = providerKernel {
    kernelPatches = [
      pkgs.kernelPatches.bridge_stp_helper
      {
        name = "synthetic-structured-config-changing-patch";
        patch = ../../../../packages/livepatch-module/tests/fixtures/a.patch;
        extraStructuredConfig.DEBUG_INFO = lib.kernel.yes;
      }
    ];
  };
  customHostConfigStdenv = pkgs.stdenv // {
    hostPlatform = pkgs.stdenv.hostPlatform // {
      linux-kernel = pkgs.stdenv.hostPlatform.linux-kernel // {
        extraConfig = "CONFIG_DEBUG_INFO y";
      };
    };
  };
  hostOverrideMetadataKernel = providerKernel {
    stdenv = customHostConfigStdenv;
  };
  builder = {
    kpatchBuild = "/nix/store/synthetic-kpatch-build";
    kpatchRevision = "bea635fbbeb11c5f0f5c0d4ffce34c2e9d2e8a6a";
  };
  payloadFunction = {
    object = "vmlinux";
    symbol = "synthetic_target";
    sympos = 0;
  };
  descriptor = {
    release = rootRelease;
    kernelVersion = fixtureKernelVersion;
    payloadRevision = 1;
    mode = "additive";
    build = {
      targets = [ "vmlinux" ];
      expected = {
        callbacks = [ ];
        functions = [ payloadFunction ];
        imports = [ ];
        relocations = [ ];
        states = [ ];
      };
    };
    fixes = [
      {
        id = "synthetic-fix";
        patchIds = [ "synthetic-patch" ];
        cves = [ ];
        functions = [ payloadFunction ];
        oracleIds = [ "synthetic-oracle" ];
        prerequisites = [ ];
        provenance = {
          source = {
            repository = "vpsfreecz/linux";
            commit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
          };
          status = "downstream-only";
          upstream = null;
          stable = null;
        };
      }
    ];
    patches = [
      {
        id = "synthetic-patch";
        path = ../../../../packages/livepatch-module/tests/fixtures/a.patch;
        fixIds = [ "synthetic-fix" ];
      }
    ];
    lineage = {
      predecessorBatch = null;
      functions = [ ];
      states = [ ];
    };
    runtime = {
      prevention = "synthetic prevention";
      removal = "synthetic removal";
      recovery = "synthetic recovery";
    };
  };
  stableDescriptor = descriptor // {
    release = "${stableKernelVersion}.1";
    kernelVersion = stableKernelVersion;
  };
  unrelatedDescriptor = descriptor // {
    release = unrelatedRelease;
    kernelVersion = unrelatedKernelVersion;
  };
  mkCatalogUnit = batchDescriptor: {
    batch = batchDescriptor;
    qualification = {
      schemaVersion = 1;
      release = batchDescriptor.release;
      requiredGenericProfiles = [ ];
      platforms = { };
      oracles = {
        "synthetic-fix" = {
          schemaVersion = 1;
          fixId = "synthetic-fix";
          oracles = [ "synthetic-oracle" ];
        };
      };
    };
    documentation = {
      page = "os/livepatches/synthetic";
      anchor = "release-${lib.replaceStrings [ "." ] [ "-" ] batchDescriptor.release}";
    };
  };
  catalogUnit = mkCatalogUnit descriptor;
  stableCatalogUnit = mkCatalogUnit stableDescriptor;
  unrelatedCatalogUnit = mkCatalogUnit unrelatedDescriptor;
  configuredTarget = livepatchLib.mkConfiguredTarget {
    kernel = configuredKernel;
    kernelVersion = fixtureKernelVersion;
    toolchain = configuredKernel.stdenv.cc;
    zfsBuiltinPkg = null;
  };
  stableConfiguredTarget = livepatchLib.mkConfiguredTarget {
    kernel = stableKernel;
    kernelVersion = stableKernelVersion;
    toolchain = stableKernel.stdenv.cc;
    zfsBuiltinPkg = null;
  };
  normalizedCatalog = livepatchLib.normalizeCatalog {
    inherit builder;
    catalog = [ catalogUnit ];
    target = configuredTarget.kernelTarget;
  };
  batch = (builtins.head normalizedCatalog).batch;
  stableNormalizedCatalog = livepatchLib.normalizeCatalog {
    inherit builder;
    catalog = [ stableCatalogUnit ];
    target = stableConfiguredTarget.kernelTarget;
  };
  stableBatch = (builtins.head stableNormalizedCatalog).batch;
  stableRelease = stableBatch.release;
  expectedBatch = batch;
  inherit (batch) installPath moduleName;
  function = builtins.head batch.build.expected.functions;
  manifestFile = pkgs.writeText "${moduleName}-manifest.json" (builtins.toJSON batch.manifest);
  modulePackage =
    (pkgs.runCommand "${moduleName}-synthetic-module" { nativeBuildInputs = [ pkgs.jq ]; } ''
      module="$out/${installPath}"
      evidence="$out/share/vpsadminos-livepatch"
      mkdir -p "$(dirname "$module")" "$evidence"
      printf 'synthetic livepatch module bytes\n' > "$module"
      sha=$(sha256sum "$module" | cut -d ' ' -f 1)
      cp ${manifestFile} "$evidence/manifest.json"
      jq -n --arg name ${lib.escapeShellArg moduleName} --arg sha "$sha" \
        '{
          buildInvocation: {
            flags: ["--non-replace"],
            nonReplaceRequested: true
          },
          module: { name: $name, sha256: $sha }
        }' > "$evidence/inspection.json"
      jq -n '{ schemaVersion: 1, matches: true, mismatches: {} }' \
        > "$evidence/closure.json"
    '').overrideAttrs
      {
        passthru = {
          inherit batch;
          kernelTarget = batch.kernelTarget;
          manifest = batch.manifest;
          targetIdentity = configuredTarget.targetBuild.identity;
        };
      };
  alterModulePackage =
    name: jqFilter:
    (pkgs.runCommand name { nativeBuildInputs = [ pkgs.jq ]; } ''
      cp -R ${modulePackage}/. "$out"
      chmod -R u+w "$out"
      inspection="$out/share/vpsadminos-livepatch/inspection.json"
      jq ${lib.escapeShellArg jqFilter} "$inspection" > "$inspection.tmp"
      mv "$inspection.tmp" "$inspection"
    '').overrideAttrs
      {
        passthru = {
          inherit batch;
          kernelTarget = batch.kernelTarget;
          manifest = batch.manifest;
          targetIdentity = configuredTarget.targetBuild.identity;
        };
      };
  replaceRequestedPackage = alterModulePackage "${moduleName}-replace-requested" ''
    .buildInvocation = {
      flags: [],
      nonReplaceRequested: false
    }
  '';
  wrongIdentityPackage = alterModulePackage "${moduleName}-wrong-identity" ''
    .module.name = "wrong_module"
  '';
  kernelImage = pkgs.writeText "synthetic-kernel-image" "synthetic kernel image\n";
  kernelNotes = pkgs.writeText "synthetic-kernel-notes" "synthetic kernel notes\n";
  fakeInsmod = pkgs.writeShellScript "livepatch-synthetic-insmod" ''
    root=${lib.escapeShellArg testRoot}
    patch="$root/sys/kernel/livepatch/${moduleName}"
    control="$root/control"
    sys_module="$root/sys/module/${moduleName}"
    scenario=$(cat "$control/scenario")
    count=0
    if [ -f "$control/insmod-count" ]; then
      count=$(cat "$control/insmod-count")
    fi
    printf '%s\n' "$((count + 1))" > "$control/insmod-count"
    mkdir -p "$sys_module"

    write_state() {
      mkdir -p "$patch/vmlinux/synthetic_target,1"
      printf '%s\n' "$1" > "$patch/enabled"
      printf '%s\n' "$2" > "$patch/transition"
      printf '%s\n' "$3" > "$patch/replace"
      printf '%s\n' "$4" > "$patch/vmlinux/patched"
    }

    case "$scenario" in
      stable)
        write_state 1 0 0 1
        printf '${rootRelease}\n' > "$control/uname"
        ;;
      delayed)
        write_state 1 1 0 1
        (
          sleep 0.10
          printf '${rootRelease}\n' > "$control/uname"
          printf '0\n' > "$patch/transition"
        ) &
        ;;
      timeout)
        write_state 1 1 0 1
        ;;
      replace)
        write_state 1 0 1 1
        ;;
      malformed)
        write_state invalid 0 0 1
        ;;
      missing)
        mkdir -p "$patch"
        ;;
      missing-coverage)
        write_state 1 0 0 0
        rm -rf "$patch/vmlinux/synthetic_target,1"
        ;;
      partial-failure)
        write_state 1 1 0 1
        exit 1
        ;;
      serialized)
        sleep 0.10
        write_state 1 0 0 1
        printf '${rootRelease}\n' > "$control/uname"
        ;;
      wrong-uname)
        write_state 1 0 0 1
        ;;
      boot-change)
        write_state 1 1 0 1
        (
          sleep 0.10
          printf 'changed notes\n' > "$root/sys/kernel/notes"
          printf '${rootRelease}\n' > "$control/uname"
          printf '0\n' > "$patch/transition"
        ) &
        ;;
      *)
        echo "unknown synthetic scenario $scenario" >&2
        exit 2
        ;;
    esac
  '';
  fakeDate = pkgs.writeShellScript "livepatch-synthetic-date" ''
    root=${lib.escapeShellArg testRoot}
    transition=$(cat "$root/sys/kernel/livepatch/${moduleName}/transition")
    if [ "$transition" != 0 ]; then
      echo "applied-at requested while transition=$transition" >&2
      exit 1
    fi
    if [ "$(cat "$root/control/uname")" != ${lib.escapeShellArg rootRelease} ]; then
      echo "applied-at requested before published uname" >&2
      exit 1
    fi
    printf 'called\n' > "$root/control/date-called"
    printf '2026-11-12T12:00:00Z\n'
  '';
  fakeUname = pkgs.writeShellScript "livepatch-synthetic-uname" ''
    test "$1" = -r
    cat ${lib.escapeShellArg "${testRoot}/control/uname"}
  '';
  fakeDisable = pkgs.writeShellScript "livepatch-synthetic-disable" ''
    root=${lib.escapeShellArg testRoot}
    patch="$root/sys/kernel/livepatch/${moduleName}"
    control="$root/control"
    scenario=$(cat "$control/scenario")
    count=0
    if [ -f "$control/disable-count" ]; then
      count=$(cat "$control/disable-count")
    fi
    printf '%s\n' "$((count + 1))" > "$control/disable-count"

    case "$scenario" in
      reverse-stable|rmmod-failure)
        printf '0\n' > "$1"
        printf '1\n' > "$patch/transition"
        (
          sleep 0.10
          printf '${fixtureKernelVersion}\n' > "$control/uname"
          printf '0\n' > "$patch/transition"
          sleep 0.05
          rm -rf "$patch"
        ) &
        ;;
      reverse-timeout)
        printf '0\n' > "$1"
        printf '1\n' > "$patch/transition"
        ;;
      reverse-wrong-uname)
        printf '0\n' > "$1"
        printf '0\n' > "$patch/transition"
        rm -rf "$patch"
        ;;
      disable-failure)
        exit 1
        ;;
      *)
        echo "unexpected disable scenario $scenario" >&2
        exit 2
        ;;
    esac
  '';
  fakeRmmod = pkgs.writeShellScript "livepatch-synthetic-rmmod" ''
    root=${lib.escapeShellArg testRoot}
    control="$root/control"
    test "$1" = ${lib.escapeShellArg moduleName}
    count=0
    if [ -f "$control/rmmod-count" ]; then
      count=$(cat "$control/rmmod-count")
    fi
    printf '%s\n' "$((count + 1))" > "$control/rmmod-count"
    if [ "$(cat "$control/scenario")" = rmmod-failure ]; then
      exit 1
    fi
    rm -rf "$root/sys/module/${moduleName}"
  '';

  syntheticLivepatchTest = {
    catalog = [ catalogUnit ];
    inherit builder;
    kpatchBuild = builder.kpatchBuild;
    livepatchModule =
      {
        batch,
        kpatchBuild,
        targetBuild,
      }:
      assert batch == expectedBatch;
      assert toString kpatchBuild == builder.kpatchBuild;
      assert targetBuild == configuredTarget.targetBuild;
      modulePackage;
    inherit kernelImage kernelNotes;
    runtime = {
      appliedDir = "${testRoot}/run/vpsadminos/livepatches";
      bootedKernel = "${testRoot}/run/booted-system/kernel";
      date = fakeDate;
      disable = fakeDisable;
      insmod = fakeInsmod;
      livepatchRoot = "${testRoot}/sys/kernel/livepatch";
      lockFile = "${testRoot}/run/lock/vpsadminos-livepatch";
      modulesRoot = "${testRoot}/lib/modules";
      bootedModulesTree = "${testRoot}/run/booted-system/kernel-modules";
      storeRoot = "${testRoot}/nix/store";
      pollAttempts = 5;
      pollInterval = "0.05";
      rmmod = fakeRmmod;
      runningNotes = "${testRoot}/sys/kernel/notes";
      sysModuleRoot = "${testRoot}/sys/module";
      uname = fakeUname;
    };
  };
  emptyCatalogTest = syntheticLivepatchTest // {
    catalog = [ ];
  };
  alteredUnrelatedCatalogTest = syntheticLivepatchTest // {
    catalog = [ unrelatedCatalogUnit ];
  };
  activationRecorder = pkgs.writeShellScript "livepatch-activation-recorder" ''
    root="''${LIVEPATCH_ACTIVATION_TEST_ROOT:?}"
    mkdir -p "$root"
    count=0
    if [ -f "$root/count" ]; then
      count=$(cat "$root/count")
    fi
    printf '%s\n' "$((count + 1))" > "$root/count"
    printf '%s\n' "$*" >> "$root/calls"
    if [ -e "$root/fail" ]; then
      exit 42
    fi
  '';
  activationLivepatchTest = syntheticLivepatchTest // {
    manager = activationRecorder;
  };
  mkModuleTest =
    package:
    syntheticLivepatchTest
    // {
      livepatchModule =
        {
          batch,
          kpatchBuild,
          targetBuild,
        }:
        assert batch == expectedBatch;
        assert toString kpatchBuild == builder.kpatchBuild;
        assert targetBuild == configuredTarget.targetBuild;
        package;
    };
  stableProductionCallerTest = syntheticLivepatchTest // {
    catalog = [ stableCatalogUnit ];
    livepatchModule =
      {
        batch,
        kpatchBuild,
        targetBuild,
      }:
      assert batch == stableBatch;
      assert toString kpatchBuild == builder.kpatchBuild;
      assert targetBuild == stableConfiguredTarget.targetBuild;
      modulePackage
      // {
        inherit batch;
        kernelTarget = batch.kernelTarget;
        manifest = batch.manifest;
        targetIdentity = targetBuild.identity;
      };
  };
  successorDescriptor = descriptor // {
    release = successorRelease;
    lineage = descriptor.lineage // {
      predecessorBatch = {
        release = descriptor.release;
        payloadRevision = descriptor.payloadRevision;
      };
      functions = [
        {
          inherit (payloadFunction) object symbol sympos;
          predecessorOwner = {
            release = descriptor.release;
            payloadRevision = descriptor.payloadRevision;
          };
        }
      ];
    };
  };
  gapDescriptor = successorDescriptor // {
    release = gapRelease;
    lineage = successorDescriptor.lineage // {
      predecessorBatch = {
        release = successorRelease;
        payloadRevision = 1;
      };
    };
  };
  ordinalTwoTest = syntheticLivepatchTest // {
    catalog = [ (mkCatalogUnit successorDescriptor) ];
  };
  gapTest = syntheticLivepatchTest // {
    catalog = [ (mkCatalogUnit gapDescriptor) ];
  };
  multiReleaseTest = syntheticLivepatchTest // {
    catalog = [
      catalogUnit
      (mkCatalogUnit successorDescriptor)
    ];
  };
  serviceModuleArgs = builtins.functionArgs (import ../default.nix);
  mkSpecialArgs =
    livepatchTest:
    {
      inherit pkgs;
      utils = { };
    }
    // lib.optionalAttrs (livepatchTest != null) { inherit livepatchTest; };
  evalService =
    {
      kernelVersion ? fixtureKernelVersion,
      kernelPackage ? mkKernel kernelVersion "${lib.replaceStrings [ "." ] [ "-" ] kernelVersion}",
      livepatchTest ? null,
      loadOnBoot ? true,
      loadOnSwitch ? false,
    }:
    (lib.evalModules {
      specialArgs = mkSpecialArgs livepatchTest;
      modules = [
        ../default.nix
        {
          options = {
            boot.kernelPackage = lib.mkOption { type = lib.types.attrs; };
            boot.kernelVersion = lib.mkOption { type = lib.types.str; };
            boot.postBootCommands = lib.mkOption {
              type = lib.types.lines;
              default = "";
            };
            boot.zfsBuiltin = lib.mkOption { type = lib.types.bool; };
            environment.etc = lib.mkOption {
              type = lib.types.attrsOf lib.types.unspecified;
              default = { };
            };
            environment.systemPackages = lib.mkOption {
              type = lib.types.listOf lib.types.package;
              default = [ ];
            };
            runit.services = lib.mkOption {
              type = lib.types.attrsOf lib.types.unspecified;
              default = { };
            };
            system.build = lib.mkOption {
              type = lib.types.attrsOf lib.types.unspecified;
              default = { };
            };
            system.activationScripts = lib.mkOption {
              type = lib.types.attrsOf lib.types.unspecified;
              default = { };
            };
          };
          config = {
            boot = {
              inherit kernelPackage;
              inherit kernelVersion;
              zfsBuiltin = false;
            };
            services.live-patches = {
              enable = true;
              inherit loadOnBoot loadOnSwitch;
            };
          };
        }
      ];
    }).config;
  emptyPrivateCatalogConfig = evalService {
    livepatchTest = emptyCatalogTest;
  };
  alteredUnrelatedCatalogConfig = evalService {
    kernelVersion = fixtureKernelVersion;
    kernelPackage = configuredKernel;
    livepatchTest = alteredUnrelatedCatalogTest;
  };
  aggregateConfig = evalService {
    kernelVersion = "6.12.48";
    livepatchTest = syntheticLivepatchTest;
  };
  retiredConfig = evalService {
    kernelVersion = "6.12.95";
    livepatchTest = syntheticLivepatchTest;
  };
  genericConfig = evalService {
    kernelVersion = fixtureKernelVersion;
    kernelPackage = configuredKernel;
    livepatchTest = syntheticLivepatchTest;
  };
  mkPolicyConfig =
    loadOnBoot: loadOnSwitch:
    evalService {
      kernelVersion = fixtureKernelVersion;
      kernelPackage = configuredKernel;
      livepatchTest = activationLivepatchTest;
      inherit loadOnBoot loadOnSwitch;
    };
  policy00 = mkPolicyConfig false false;
  policy01 = mkPolicyConfig false true;
  policy10 = mkPolicyConfig true false;
  policy11 = mkPolicyConfig true true;
  policies = [
    policy00
    policy01
    policy10
    policy11
  ];
  policyIdentity = policy: {
    batch = policy.system.build.livePatchModules.${rootRelease}.batch;
    drvPath = policy.system.build.livePatchModules.${rootRelease}.drvPath;
    inputDigest = policy.system.build.livePatchModules.${rootRelease}.batch.inputDigest;
    installPath = policy.system.build.livePatchModules.${rootRelease}.batch.installPath;
    kernelTarget = policy.system.build.livePatchModules.${rootRelease}.kernelTarget;
    manifest = policy.system.build.livePatchModules.${rootRelease}.manifest;
    moduleName = policy.system.build.livePatchModules.${rootRelease}.batch.moduleName;
    producerDigest = policy.system.build.livePatchModules.${rootRelease}.batch.producerDigest;
    targetIdentity = policy.system.build.livePatchModules.${rootRelease}.targetIdentity;
  };
  policyIdentity0 = policyIdentity policy00;
  oldRuntimeResult = builtins.tryEval (
    builtins.deepSeq (livepatchLib.normalizeCatalog {
      inherit builder;
      catalog = [
        (mkCatalogUnit (
          descriptor
          // {
            runtime = descriptor.runtime // {
              bootAutoload = false;
            };
          }
        ))
      ];
      target = configuredTarget.kernelTarget;
    }) true
  );
  boot10 = pkgs.writeText "livepatch-activation-boot-10" policy10.boot.postBootCommands;
  boot11 = pkgs.writeText "livepatch-activation-boot-11" policy11.boot.postBootCommands;
  switch01 = pkgs.writeText "livepatch-activation-switch-01" (
    policy01.system.activationScripts.livePatches.text
  );
  switch11 = pkgs.writeText "livepatch-activation-switch-11" (
    policy11.system.activationScripts.livePatches.text
  );
  replaceRequestedConfig = evalService {
    kernelVersion = fixtureKernelVersion;
    kernelPackage = configuredKernel;
    livepatchTest = mkModuleTest replaceRequestedPackage;
  };
  wrongIdentityConfig = evalService {
    kernelVersion = fixtureKernelVersion;
    kernelPackage = configuredKernel;
    livepatchTest = mkModuleTest wrongIdentityPackage;
  };
  mismatchedTargetResult = builtins.tryEval (
    (evalService {
      kernelVersion = fixtureKernelVersion;
      kernelPackage = mkKernel fixtureKernelVersion "b";
      livepatchTest = syntheticLivepatchTest;
    }).system.build.livePatchManager.drvPath
  );
  stableProductionConfig = evalService {
    kernelVersion = stableKernelVersion;
    kernelPackage = stableKernel;
    livepatchTest = stableProductionCallerTest;
  };
  ordinalTwoResult = builtins.tryEval (
    (evalService {
      kernelVersion = fixtureKernelVersion;
      kernelPackage = configuredKernel;
      livepatchTest = ordinalTwoTest;
    }).system.build.livePatchManager.drvPath
  );
  gapResult = builtins.tryEval (
    (evalService {
      kernelVersion = fixtureKernelVersion;
      kernelPackage = configuredKernel;
      livepatchTest = gapTest;
    }).system.build.livePatchManager.drvPath
  );
  multiReleaseResult = builtins.tryEval (
    (evalService {
      kernelVersion = fixtureKernelVersion;
      kernelPackage = configuredKernel;
      livepatchTest = multiReleaseTest;
    }).system.build.livePatchManager.drvPath
  );
in

assert serviceModuleArgs ? specialArgs;
assert !(serviceModuleArgs ? livepatchTest);
assert !(mkSpecialArgs null ? livepatchTest);
assert (mkSpecialArgs syntheticLivepatchTest).livepatchTest == syntheticLivepatchTest;
assert livepatchMetadata stableKernel == expectedLivepatchMetadata;
assert livepatchMetadata kernel113 == expectedLivepatchMetadata;
assert livepatchMetadata (providerKernel { }) == expectedLivepatchMetadata;
assert livepatchMetadata non612MetadataKernel == missingLivepatchMetadata;
assert livepatchMetadata wrongArchitectureMetadataKernel == missingLivepatchMetadata;
assert livepatchMetadata customDefconfigMetadataKernel == missingLivepatchMetadata;
assert livepatchMetadata legacyOverrideMetadataKernel == missingLivepatchMetadata;
assert livepatchMetadata structuredOverrideMetadataKernel == missingLivepatchMetadata;
assert livepatchMetadata rtMetadataKernel == missingLivepatchMetadata;
assert livepatchMetadata configPatchMetadataKernel == missingLivepatchMetadata;
assert livepatchMetadata structuredConfigPatchMetadataKernel == missingLivepatchMetadata;
assert livepatchMetadata hostOverrideMetadataKernel == missingLivepatchMetadata;
assert
  builtins.attrNames descriptor == [
    "build"
    "fixes"
    "kernelVersion"
    "lineage"
    "mode"
    "patches"
    "payloadRevision"
    "release"
    "runtime"
  ];
assert emptyCatalogTest.catalog == [ ];
assert !(emptyPrivateCatalogConfig.system.build ? livePatchModules);
assert !(emptyPrivateCatalogConfig.system.build ? livePatchManager);
assert !(emptyPrivateCatalogConfig.environment.etc ? "vpsadminos/livepatch-monitor.json");
assert emptyPrivateCatalogConfig.runit.services.live-patches.run == "sleep inf";
assert emptyPrivateCatalogConfig.runit.services.live-patches.finish == "";
assert alteredUnrelatedCatalogTest.catalog == [ unrelatedCatalogUnit ];
assert !(alteredUnrelatedCatalogConfig.system.build ? livePatchModules);
assert !(alteredUnrelatedCatalogConfig.system.build ? livePatchManager);
assert !(alteredUnrelatedCatalogConfig.environment.etc ? "vpsadminos/livepatch-monitor.json");
assert alteredUnrelatedCatalogConfig.runit.services.live-patches.run == "sleep inf";
assert alteredUnrelatedCatalogConfig.runit.services.live-patches.finish == "";
assert !(aggregateConfig.system.build ? livePatchModules);
assert !(aggregateConfig.system.build ? livePatchManager);
assert aggregateConfig.system.build ? livePatches;
assert aggregateConfig.runit.services.live-patches.run == "sleep inf";
assert aggregateConfig.runit.services.live-patches.finish == "";
assert
  (builtins.fromJSON (
    builtins.unsafeDiscardStringContext
      aggregateConfig.environment.etc."vpsadminos/livepatch-monitor.json".text
  )).module != moduleName;
assert !(retiredConfig.system.build ? livePatchModules);
assert !(retiredConfig.system.build ? livePatchManager);
assert !(retiredConfig.system.build ? livePatches);
assert !(retiredConfig.environment.etc ? "vpsadminos/livepatch-monitor.json");
assert retiredConfig.runit.services.live-patches.run == "sleep inf";
assert retiredConfig.runit.services.live-patches.finish == "";
assert genericConfig.runit.services.live-patches.run == "sleep inf";
assert genericConfig.runit.services.live-patches.finish == "";
assert policy00.boot.postBootCommands == "";
assert policy01.boot.postBootCommands == "";
assert !(policy00.system.activationScripts ? livePatches);
assert !(policy10.system.activationScripts ? livePatches);
assert policy00.services.live-patches.loadOnBoot == false;
assert policy00.services.live-patches.loadOnSwitch == false;
assert policy01.services.live-patches.loadOnBoot == false;
assert policy01.services.live-patches.loadOnSwitch == true;
assert policy10.services.live-patches.loadOnBoot == true;
assert policy10.services.live-patches.loadOnSwitch == false;
assert policy11.services.live-patches.loadOnBoot == true;
assert policy11.services.live-patches.loadOnSwitch == true;
assert lib.all (policy: policyIdentity policy == policyIdentity0) policies;
assert !oldRuntimeResult.success;
assert genericConfig.environment.etc."vpsadminos/livepatch-monitor.json".text != "";
assert genericConfig.system.build.livePatchModules.${rootRelease} == modulePackage;
assert !mismatchedTargetResult.success;
assert !ordinalTwoResult.success;
assert !gapResult.success;
assert !multiReleaseResult.success;
assert stableDescriptor.kernelVersion == stableKernelOwner.defaultVersion;
assert stableKernel.modDirVersion == stableKernelOwner.defaultVersion;
assert stableBatch.kernelTarget.kernelVersion == stableKernelOwner.defaultVersion;
assert
  stableProductionConfig.system.build.livePatchModules.${stableRelease}.kernelTarget
  == stableConfiguredTarget.kernelTarget;
assert
  stableProductionConfig.system.build.livePatchModules.${stableRelease}.targetIdentity
  == stableConfiguredTarget.targetBuild.identity;
assert
  (builtins.fromJSON (
    builtins.unsafeDiscardStringContext
      genericConfig.environment.etc."vpsadminos/livepatch-monitor.json".text
  )).patchVersion == 1;
assert batch.mode == "additive";
assert batch.unameLevel.protocol == "vpsadminos-additive-uname-v1";
assert batch.unameLevel.releaseOrdinal == 1;
assert batch.unameLevel.predecessorOrdinal == null;
assert batch.unameLevel.rollbackRelease == fixtureKernelVersion;
assert batch.unameLevel.publishedRelease == rootRelease;
assert builtins.length batch.build.expected.callbacks == 3;
assert builtins.length batch.build.expected.states == 1;
pkgs.runCommand "livepatch-scalar-manager-unit" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  empty_manager=${lib.escapeShellArg "${builtins.head emptyPrivateCatalogConfig.environment.systemPackages}/bin/live-patches"}
  test "$("$empty_manager" load)" = "Live Patching not enabled in machine config or no patches available"
  test ! -e ${lib.escapeShellArg "${testRoot}/run/vpsadminos/livepatches"}
  python ${./test_manager.py} \
    ${lib.escapeShellArg pkgs.runtimeShell} \
    ${genericConfig.system.build.livePatchManager}/bin/live-patches \
    ${lib.escapeShellArg testRoot} \
    ${lib.escapeShellArg kernelImage} \
    ${lib.escapeShellArg kernelNotes} \
    ${lib.escapeShellArg moduleName} \
    ${replaceRequestedConfig.system.build.livePatchManager}/bin/live-patches \
    ${wrongIdentityConfig.system.build.livePatchManager}/bin/live-patches

  activation_root="$TMPDIR/activation"
  export LIVEPATCH_ACTIVATION_TEST_ROOT="$activation_root"
  call_count() {
    if [ -f "$activation_root/count" ]; then
      cat "$activation_root/count"
    else
      printf '0\n'
    fi
  }
  reset_calls() {
    rm -rf "$activation_root"
    mkdir -p "$activation_root"
  }
  run_switch() {
    booted_present="$1"
    script="$2"
    test() {
      case "$*" in
        '-e /run/booted-system')
          builtin test "$booted_present" = 1
          ;;
        *)
          builtin test "$@"
          ;;
      esac
    }
    . "$script"
    unset -f test
  }

  reset_calls
  ${pkgs.runtimeShell} ${boot10}
  test "$(call_count)" = 1
  test "$(cat "$activation_root/calls")" = load

  reset_calls
  ${pkgs.runtimeShell} ${boot11}
  test "$(call_count)" = 1

  reset_calls
  run_switch 0 ${switch01}
  test "$(call_count)" = 0
  run_switch 1 ${switch01}
  test "$(call_count)" = 1
  run_switch 1 ${switch01}
  run_switch 1 ${switch01}
  test "$(call_count)" = 3

  reset_calls
  run_switch 0 ${switch11}
  test "$(call_count)" = 0
  run_switch 1 ${switch11}
  test "$(call_count)" = 1

  reset_calls
  touch "$activation_root/fail"
  ${pkgs.runtimeShell} ${boot10}
  test "$(call_count)" = 1

  test ${lib.escapeShellArg policy00.runit.services.live-patches.run} = 'sleep inf'
  test -z ${lib.escapeShellArg policy00.runit.services.live-patches.finish}
  test ${lib.escapeShellArg policy11.runit.services.live-patches.run} = 'sleep inf'
  test -z ${lib.escapeShellArg policy11.runit.services.live-patches.finish}
  touch "$out"
''
