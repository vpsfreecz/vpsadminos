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
  stableHasLivepatchMetadata = stableKernel.config.isSet "SMP";
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
        # Evaluation-only exercise of the provider's known metadata shape.
        version = "6.12.0";
        modDirVersion = "6.12.0";
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
  successorDescriptor = descriptor // {
    release = successorRelease;
    payloadRevision = 2;
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
  thirdDescriptor = successorDescriptor // {
    release = gapRelease;
    payloadRevision = 3;
    lineage = successorDescriptor.lineage // {
      predecessorBatch = {
        release = successorDescriptor.release;
        payloadRevision = successorDescriptor.payloadRevision;
      };
      functions = [
        {
          inherit (payloadFunction) object symbol sympos;
          predecessorOwner = {
            release = successorDescriptor.release;
            payloadRevision = successorDescriptor.payloadRevision;
          };
        }
      ];
    };
  };
  gapDescriptor = thirdDescriptor;
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
  successorCatalogUnit = mkCatalogUnit successorDescriptor;
  thirdCatalogUnit = mkCatalogUnit thirdDescriptor;
  fullCatalog = [
    catalogUnit
    successorCatalogUnit
    thirdCatalogUnit
  ];
  stableCatalogUnit = mkCatalogUnit stableDescriptor;
  unrelatedCatalogUnit = mkCatalogUnit unrelatedDescriptor;
  configuredTarget = livepatchLib.mkConfiguredTarget {
    kernel = configuredKernel;
    kernelVersion = fixtureKernelVersion;
    toolchain = configuredKernel.stdenv.cc;
    zfsBuiltinPkg = null;
  };
  stableTargetKernel =
    if stableHasLivepatchMetadata then stableKernel else mkKernel stableKernelVersion "stable";
  stableConfiguredTarget = livepatchLib.mkConfiguredTarget {
    kernel = stableTargetKernel;
    kernelVersion = stableKernelVersion;
    toolchain = stableTargetKernel.stdenv.cc;
    zfsBuiltinPkg = null;
  };
  rootNormalizedCatalog = livepatchLib.normalizeCatalog {
    inherit builder;
    catalog = [ catalogUnit ];
    target = configuredTarget.kernelTarget;
  };
  normalizedCatalog = livepatchLib.normalizeCatalog {
    inherit builder;
    catalog = fullCatalog;
    target = configuredTarget.kernelTarget;
  };
  batches = map (unit: unit.batch) normalizedCatalog;
  batch = builtins.head batches;
  stableNormalizedCatalog = livepatchLib.normalizeCatalog {
    inherit builder;
    catalog = [ stableCatalogUnit ];
    target = stableConfiguredTarget.kernelTarget;
  };
  stableBatch = (builtins.head stableNormalizedCatalog).batch;
  stableRelease = stableBatch.release;
  expectedBatch = (builtins.head rootNormalizedCatalog).batch;
  assertRootIdentity =
    assert batch == expectedBatch;
    true;
  inherit (batch) installPath moduleName;
  function = builtins.head batch.build.expected.functions;
  mkModulePackage =
    selectedBatch:
    let
      selectedManifest = pkgs.writeText "${selectedBatch.moduleName}-manifest.json" (
        builtins.toJSON selectedBatch.manifest
      );
    in
    (pkgs.runCommand "${selectedBatch.moduleName}-synthetic-module" { nativeBuildInputs = [ pkgs.jq ]; }
      ''
        module="$out/${selectedBatch.installPath}"
        evidence="$out/share/vpsadminos-livepatch"
        mkdir -p "$(dirname "$module")" "$evidence"
        printf 'synthetic livepatch module %s bytes\n' ${lib.escapeShellArg selectedBatch.release} > "$module"
        sha=$(sha256sum "$module" | cut -d ' ' -f 1)
        cp ${selectedManifest} "$evidence/manifest.json"
        jq -n --arg name ${lib.escapeShellArg selectedBatch.moduleName} --arg sha "$sha" \
          '{
            buildInvocation: {
              flags: ["--non-replace"],
              nonReplaceRequested: true
            },
            module: { name: $name, sha256: $sha }
          }' > "$evidence/inspection.json"
        jq -n '{ schemaVersion: 1, matches: true, mismatches: {} }' \
          > "$evidence/closure.json"
      ''
    ).overrideAttrs
      {
        passthru = {
          batch = selectedBatch;
          kernelTarget = selectedBatch.kernelTarget;
          manifest = selectedBatch.manifest;
          targetIdentity = configuredTarget.targetBuild.identity;
        };
      };
  modulePackages = map mkModulePackage batches;
  modulePackagesByRelease = builtins.listToAttrs (
    lib.imap0 (index: selectedBatch: {
      name = selectedBatch.release;
      value = builtins.elemAt modulePackages index;
    }) batches
  );
  modulePackage = modulePackagesByRelease.${rootRelease};
  mutateModulePackage =
    name: mutation:
    (pkgs.runCommand name { nativeBuildInputs = [ pkgs.jq ]; } ''
      cp -R ${modulePackage}/. "$out"
      chmod -R u+w "$out"
      ${mutation}
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
    mutateModulePackage name ''
      inspection="$out/share/vpsadminos-livepatch/inspection.json"
      jq ${lib.escapeShellArg jqFilter} "$inspection" > "$inspection.tmp"
      mv "$inspection.tmp" "$inspection"
    '';
  replaceRequestedPackage = alterModulePackage "${moduleName}-replace-requested" ''
    .buildInvocation = {
      flags: [],
      nonReplaceRequested: false
    }
  '';
  wrongIdentityPackage = alterModulePackage "${moduleName}-wrong-identity" ''
    .module.name = "wrong_module"
  '';
  missingArtifactPackage = mutateModulePackage "${moduleName}-missing-artifact" ''
    rm "$out/${batch.installPath}"
  '';
  wrongManifestPackage = mutateModulePackage "${moduleName}-wrong-manifest" ''
    printf '{}\n' > "$out/share/vpsadminos-livepatch/manifest.json"
  '';
  wrongHashPackage = alterModulePackage "${moduleName}-wrong-hash" ''
    .module.sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
  '';
  malformedInspectionPackage = mutateModulePackage "${moduleName}-malformed-inspection" ''
    printf '{\n' > "$out/share/vpsadminos-livepatch/inspection.json"
  '';
  malformedClosurePackage = mutateModulePackage "${moduleName}-malformed-closure" ''
    printf '{\n' > "$out/share/vpsadminos-livepatch/closure.json"
  '';
  unreadableInspectionPackage = mutateModulePackage "${moduleName}-unreadable-inspection" ''
    rm "$out/share/vpsadminos-livepatch/inspection.json"
    ln -s /proc/self/mem "$out/share/vpsadminos-livepatch/inspection.json"
  '';
  unreadableClosurePackage = mutateModulePackage "${moduleName}-unreadable-closure" ''
    rm "$out/share/vpsadminos-livepatch/closure.json"
    ln -s /proc/self/mem "$out/share/vpsadminos-livepatch/closure.json"
  '';
  unreadableHashPackage = mutateModulePackage "${moduleName}-unreadable-hash" ''
    rm "$out/${batch.installPath}"
    ln -s /proc/self/mem "$out/${batch.installPath}"
  '';
  kernelImage = pkgs.writeText "synthetic-kernel-image" "synthetic kernel image\n";
  kernelNotes = pkgs.writeText "synthetic-kernel-notes" "synthetic kernel notes\n";
  selectSyntheticBatch = lib.concatMapStringsSep "\n" (selectedBatch: ''
    ${lib.escapeShellArg selectedBatch.moduleName})
      ordinal=${toString selectedBatch.unameLevel.releaseOrdinal}
      published_release=${lib.escapeShellArg selectedBatch.unameLevel.publishedRelease}
      rollback_release=${lib.escapeShellArg selectedBatch.unameLevel.rollbackRelease}
      ;;
  '') batches;
  fakeInsmod = pkgs.writeShellScript "livepatch-synthetic-insmod" ''
    root=${lib.escapeShellArg testRoot}
    module_file="$1"
    module_base="''${module_file##*/}"
    module_name="''${module_base%.ko}"
    case "$module_name" in
      ${selectSyntheticBatch}
      *) echo "unexpected module $module_name" >&2; exit 2 ;;
    esac
    patch="$root/sys/kernel/livepatch/$module_name"
    control="$root/control"
    sys_module="$root/sys/module/$module_name"
    scenario=$(cat "$control/scenario")
    order=
    if [ -f "$control/insmod-order" ]; then
      order=$(cat "$control/insmod-order")
    fi
    printf '%s%s\n' "$order" "$ordinal" > "$control/insmod-order"
    mkdir -p "$sys_module"

    write_state() {
      mkdir -p "$patch/vmlinux/synthetic_target,1"
      printf '%s\n' "$1" > "$patch/enabled"
      printf '%s\n' "$2" > "$patch/transition"
      printf '%s\n' "$3" > "$patch/replace"
      printf '%s\n' "$4" > "$patch/vmlinux/patched"
    }

    case "$scenario:$ordinal" in
      insmod-failure-*:$ordinal)
        failure_ordinal="''${scenario##*-}"
        if [ "$failure_ordinal" = "$ordinal" ]; then
          write_state 1 1 0 1
          exit 1
        fi
        write_state 1 0 0 1
        printf '%s\n' "$published_release" > "$control/uname"
        ;;
      timeout-*:$ordinal)
        failure_ordinal="''${scenario##*-}"
        if [ "$failure_ordinal" = "$ordinal" ]; then
          write_state 1 1 0 1
        else
          write_state 1 0 0 1
          printf '%s\n' "$published_release" > "$control/uname"
        fi
        ;;
      replace-*:$ordinal)
        failure_ordinal="''${scenario##*-}"
        if [ "$failure_ordinal" = "$ordinal" ]; then
          write_state 1 0 1 1
        else
          write_state 1 0 0 1
          printf '%s\n' "$published_release" > "$control/uname"
        fi
        ;;
      malformed-*:$ordinal)
        failure_ordinal="''${scenario##*-}"
        write_state 1 0 0 1
        if [ "$failure_ordinal" = "$ordinal" ]; then
          printf 'malformed\n' > "$patch/enabled"
        else
          printf '%s\n' "$published_release" > "$control/uname"
        fi
        ;;
      missing-state-*:$ordinal)
        failure_ordinal="''${scenario##*-}"
        write_state 1 0 0 1
        if [ "$failure_ordinal" = "$ordinal" ]; then
          rm "$patch/enabled"
        else
          printf '%s\n' "$published_release" > "$control/uname"
        fi
        ;;
      missing-coverage-*:$ordinal)
        failure_ordinal="''${scenario##*-}"
        write_state 1 0 0 1
        printf '%s\n' "$published_release" > "$control/uname"
        if [ "$failure_ordinal" = "$ordinal" ]; then
          printf '0\n' > "$patch/vmlinux/patched"
          rm -rf "$patch/vmlinux/synthetic_target,1"
        fi
        ;;
      wrong-uname-*:$ordinal)
        failure_ordinal="''${scenario##*-}"
        write_state 1 0 0 1
        if [ "$failure_ordinal" != "$ordinal" ]; then
          printf '%s\n' "$published_release" > "$control/uname"
        fi
        ;;
      delayed-*:$ordinal)
        failure_ordinal="''${scenario##*-}"
        if [ "$failure_ordinal" = "$ordinal" ]; then
          write_state 1 1 0 1
          (
            sleep 0.10
            printf '%s\n' "$published_release" > "$control/uname"
            printf '0\n' > "$patch/transition"
          ) &
        else
          write_state 1 0 0 1
          printf '%s\n' "$published_release" > "$control/uname"
        fi
        ;;
      stable:*|serialized:*|marker-publication-failure-*:$ordinal)
        write_state 1 0 0 1
        printf '%s\n' "$published_release" > "$control/uname"
        ;;
      *)
        echo "unknown synthetic scenario $scenario for ordinal $ordinal" >&2
        exit 2
        ;;
    esac
  '';
  fakeDate = pkgs.writeShellScript "livepatch-synthetic-date" ''
    root=${lib.escapeShellArg testRoot}
    for transition_file in "$root"/sys/kernel/livepatch/*/transition; do
      [ -e "$transition_file" ] || continue
      transition=$(cat "$transition_file")
      if [ "$transition" != 0 ]; then
        echo "applied-at requested while transition=$transition" >&2
        exit 1
      fi
    done
    count=0
    if [ -f "$root/control/date-count" ]; then
      count=$(cat "$root/control/date-count")
    fi
    scenario=$(cat "$root/control/scenario")
    if [ "$scenario" = "marker-publication-failure-$((count + 1))" ]; then
      echo "synthetic applied-marker publication failure" >&2
      exit 1
    fi
    printf '%s\n' "$((count + 1))" > "$root/control/date-count"
    printf '2026-11-12T12:00:00Z\n'
  '';
  fakeUname = pkgs.writeShellScript "livepatch-synthetic-uname" ''
    test "$1" = -r
    cat ${lib.escapeShellArg "${testRoot}/control/uname"}
  '';
  fakeDisable = pkgs.writeShellScript "livepatch-synthetic-disable" ''
    root=${lib.escapeShellArg testRoot}
    patch="''${1%/enabled}"
    module_name="''${patch##*/}"
    case "$module_name" in
      ${selectSyntheticBatch}
      *) echo "unexpected module $module_name" >&2; exit 2 ;;
    esac
    control="$root/control"
    scenario=$(cat "$control/scenario")
    order=
    if [ -f "$control/disable-order" ]; then
      order=$(cat "$control/disable-order")
    fi
    printf '%s%s\n' "$order" "$ordinal" > "$control/disable-order"

    case "$scenario:$ordinal" in
      reverse-timeout-*:$ordinal)
        failure_ordinal="''${scenario##*-}"
        printf '0\n' > "$1"
        printf '1\n' > "$patch/transition"
        if [ "$failure_ordinal" != "$ordinal" ]; then
          printf '%s\n' "$rollback_release" > "$control/uname"
          printf '0\n' > "$patch/transition"
          rm -rf "$patch"
        fi
        ;;
      disable-failure-*:$ordinal)
        failure_ordinal="''${scenario##*-}"
        if [ "$failure_ordinal" = "$ordinal" ]; then
          exit 1
        fi
        printf '0\n' > "$1"
        printf '%s\n' "$rollback_release" > "$control/uname"
        rm -rf "$patch"
        ;;
      reverse-stable:*|rmmod-failure-*:$ordinal)
        printf '0\n' > "$1"
        printf '1\n' > "$patch/transition"
        printf '%s\n' "$rollback_release" > "$control/uname"
        printf '0\n' > "$patch/transition"
        rm -rf "$patch"
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
    module_name="$1"
    case "$module_name" in
      ${selectSyntheticBatch}
      *) echo "unexpected module $module_name" >&2; exit 2 ;;
    esac
    order=
    if [ -f "$control/rmmod-order" ]; then
      order=$(cat "$control/rmmod-order")
    fi
    printf '%s%s\n' "$order" "$ordinal" > "$control/rmmod-order"
    scenario=$(cat "$control/scenario")
    if [ "$scenario" = "rmmod-failure-$ordinal" ]; then
      exit 1
    fi
    rm -rf "$root/sys/module/$module_name"
  '';

  syntheticLivepatchTest = {
    catalog = fullCatalog;
    inherit builder;
    kpatchBuild = builder.kpatchBuild;
    livepatchModule =
      {
        batch,
        kpatchBuild,
        targetBuild,
      }:
      assert toString kpatchBuild == builder.kpatchBuild;
      assert targetBuild == configuredTarget.targetBuild;
      modulePackagesByRelease.${batch.release};
    inherit kernelImage kernelNotes;
    runtime = {
      appliedDir = "${testRoot}/run/vpsadminos/livepatches";
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
  rootOnlyTest = syntheticLivepatchTest // {
    catalog = [ catalogUnit ];
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
        assert toString kpatchBuild == builder.kpatchBuild;
        assert targetBuild == configuredTarget.targetBuild;
        if batch.release == rootRelease then package else modulePackagesByRelease.${batch.release};
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
  rootOnlyConfig = evalService {
    kernelVersion = fixtureKernelVersion;
    kernelPackage = configuredKernel;
    livepatchTest = rootOnlyTest;
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
  policyIdentity =
    policy:
    lib.mapAttrs (_release: module: {
      inherit (module)
        drvPath
        kernelTarget
        manifest
        targetIdentity
        ;
      inherit (module.batch)
        inputDigest
        installPath
        moduleName
        producerDigest
        ;
      batch = module.batch;
    }) policy.system.build.livePatchModules;
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
  missingArtifactConfig = evalService {
    kernelVersion = fixtureKernelVersion;
    kernelPackage = configuredKernel;
    livepatchTest = mkModuleTest missingArtifactPackage;
  };
  wrongManifestConfig = evalService {
    kernelVersion = fixtureKernelVersion;
    kernelPackage = configuredKernel;
    livepatchTest = mkModuleTest wrongManifestPackage;
  };
  wrongHashConfig = evalService {
    kernelVersion = fixtureKernelVersion;
    kernelPackage = configuredKernel;
    livepatchTest = mkModuleTest wrongHashPackage;
  };
  malformedInspectionConfig = evalService {
    kernelVersion = fixtureKernelVersion;
    kernelPackage = configuredKernel;
    livepatchTest = mkModuleTest malformedInspectionPackage;
  };
  malformedClosureConfig = evalService {
    kernelVersion = fixtureKernelVersion;
    kernelPackage = configuredKernel;
    livepatchTest = mkModuleTest malformedClosurePackage;
  };
  unreadableInspectionConfig = evalService {
    kernelVersion = fixtureKernelVersion;
    kernelPackage = configuredKernel;
    livepatchTest = mkModuleTest unreadableInspectionPackage;
  };
  unreadableClosureConfig = evalService {
    kernelVersion = fixtureKernelVersion;
    kernelPackage = configuredKernel;
    livepatchTest = mkModuleTest unreadableClosurePackage;
  };
  unreadableHashConfig = evalService {
    kernelVersion = fixtureKernelVersion;
    kernelPackage = configuredKernel;
    livepatchTest = mkModuleTest unreadableHashPackage;
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
    kernelPackage = stableTargetKernel;
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
  multiReleaseConfig = evalService {
    kernelVersion = fixtureKernelVersion;
    kernelPackage = configuredKernel;
    livepatchTest = multiReleaseTest;
  };
  genericMonitor = builtins.fromJSON (
    builtins.unsafeDiscardStringContext
      genericConfig.environment.etc."vpsadminos/livepatch-monitor.json".text
  );
  moduleNamesFile = pkgs.writeText "livepatch-synthetic-module-names.json" (
    builtins.toJSON (map (selectedBatch: selectedBatch.moduleName) batches)
  );
in

assert serviceModuleArgs ? specialArgs;
assert !(serviceModuleArgs ? livepatchTest);
assert !(mkSpecialArgs null ? livepatchTest);
assert (mkSpecialArgs syntheticLivepatchTest).livepatchTest == syntheticLivepatchTest;
assert
  if stableHasLivepatchMetadata then
    lib.all (
      value:
      builtins.elem value [
        "y"
        "n"
      ]
    ) (livepatchMetadata stableKernel)
  else
    livepatchMetadata stableKernel == missingLivepatchMetadata;
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
assert
  builtins.attrNames multiReleaseConfig.system.build.livePatchModules == [
    rootRelease
    successorRelease
  ];
assert stableDescriptor.kernelVersion == stableKernelOwner.defaultVersion;
assert stableKernel.modDirVersion == stableKernelOwner.defaultVersion;
assert stableBatch.kernelTarget.kernelVersion == stableKernelOwner.defaultVersion;
assert
  stableProductionConfig.system.build.livePatchModules.${stableRelease}.kernelTarget
  == stableConfiguredTarget.kernelTarget;
assert
  stableProductionConfig.system.build.livePatchModules.${stableRelease}.targetIdentity
  == stableConfiguredTarget.targetBuild.identity;
assert genericMonitor.schemaVersion == 2;
assert genericMonitor.kernelVersion == fixtureKernelVersion;
assert builtins.length genericMonitor.modules == 3;
assert
  map (entry: entry.patchVersion) genericMonitor.modules == [
    1
    2
    3
  ];
assert map (entry: entry.module) genericMonitor.modules == map (entry: entry.moduleName) batches;
assert batch.mode == "additive";
assert batch.unameLevel.protocol == "vpsadminos-additive-uname-v1";
assert batch.unameLevel.releaseOrdinal == 1;
assert batch.unameLevel.predecessorOrdinal == null;
assert batch.unameLevel.rollbackRelease == fixtureKernelVersion;
assert batch.unameLevel.publishedRelease == rootRelease;
assert builtins.length batch.build.expected.callbacks == 3;
assert builtins.length batch.build.expected.states == 1;
pkgs.runCommand "livepatch-stack-manager-unit" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  empty_manager=${lib.escapeShellArg "${builtins.head emptyPrivateCatalogConfig.environment.systemPackages}/bin/live-patches"}
  test "$("$empty_manager" load)" = "Live Patching not enabled in machine config or no patches available"
  test ! -e ${lib.escapeShellArg "${testRoot}/run/vpsadminos/livepatches"}
  manager=${genericConfig.system.build.livePatchManager}/bin/live-patches
  if ${pkgs.gnugrep}/bin/grep -F 'check_boot_identity' "$manager" || \
     ${pkgs.gnugrep}/bin/grep -F 'running boot-kernel' "$manager" || \
     ${pkgs.gnugrep}/bin/grep -F '/sys/kernel/notes' "$manager"; then
    echo 'generated manager retains boot-image or notes admission' >&2
    exit 1
  fi
  python ${./test_manager.py} \
    ${lib.escapeShellArg pkgs.runtimeShell} \
    "$manager" \
    ${lib.escapeShellArg testRoot} \
    ${lib.escapeShellArg kernelImage} \
    ${lib.escapeShellArg kernelNotes} \
    ${moduleNamesFile} \
    ${rootOnlyConfig.system.build.livePatchManager}/bin/live-patches \
    ${replaceRequestedConfig.system.build.livePatchManager}/bin/live-patches \
    ${wrongIdentityConfig.system.build.livePatchManager}/bin/live-patches \
    ${missingArtifactConfig.system.build.livePatchManager}/bin/live-patches \
    ${wrongManifestConfig.system.build.livePatchManager}/bin/live-patches \
    ${wrongHashConfig.system.build.livePatchManager}/bin/live-patches \
    ${malformedInspectionConfig.system.build.livePatchManager}/bin/live-patches \
    ${malformedClosureConfig.system.build.livePatchManager}/bin/live-patches \
    ${unreadableInspectionConfig.system.build.livePatchManager}/bin/live-patches \
    ${unreadableClosureConfig.system.build.livePatchManager}/bin/live-patches \
    ${unreadableHashConfig.system.build.livePatchManager}/bin/live-patches

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
