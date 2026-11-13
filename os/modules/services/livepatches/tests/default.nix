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
  configuredKernel = mkKernel "6.12.113" "a";
  realKernelDefinition =
    (import ../../../../packages/linux/available-kernels.nix { inherit lib; }).kernels."6.12.113";
  realKernel = pkgs.callPackage ../../../../packages/linux {
    kernelVersion = "6.12.113";
    url = "https://github.com/vpsfreecz/linux/archive/${realKernelDefinition.rev}.tar.gz";
    sha256 = realKernelDefinition.sha256;
    structuredExtraConfig = realKernelDefinition.structuredExtraConfig or { };
    features = realKernelDefinition.features or { };
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
    release = "6.12.113.1";
    kernelVersion = "6.12.113";
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
      bootAutoload = false;
      prevention = "synthetic prevention";
      removal = "synthetic removal";
      recovery = "synthetic recovery";
    };
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
  configuredTarget = livepatchLib.mkConfiguredTarget {
    kernel = configuredKernel;
    kernelVersion = "6.12.113";
    toolchain = configuredKernel.stdenv.cc;
    zfsBuiltinPkg = null;
  };
  realConfiguredTarget = livepatchLib.mkConfiguredTarget {
    kernel = realKernel;
    kernelVersion = "6.12.113";
    toolchain = realKernel.stdenv.cc;
    zfsBuiltinPkg = null;
  };
  normalizedCatalog = livepatchLib.normalizeCatalog {
    inherit builder;
    catalog = [ catalogUnit ];
    target = configuredTarget.kernelTarget;
  };
  batch = (builtins.head normalizedCatalog).batch;
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
        printf '6.12.113.1\n' > "$control/uname"
        ;;
      delayed)
        write_state 1 1 0 1
        (
          sleep 0.10
          printf '6.12.113.1\n' > "$control/uname"
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
        printf '6.12.113.1\n' > "$control/uname"
        ;;
      wrong-uname)
        write_state 1 0 0 1
        ;;
      boot-change)
        write_state 1 1 0 1
        (
          sleep 0.10
          printf 'changed notes\n' > "$root/sys/kernel/notes"
          printf '6.12.113.1\n' > "$control/uname"
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
    if [ "$(cat "$root/control/uname")" != "6.12.113.1" ]; then
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
          printf '6.12.113\n' > "$control/uname"
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
  realProductionCallerTest = syntheticLivepatchTest // {
    livepatchModule =
      {
        batch,
        kpatchBuild,
        targetBuild,
      }:
      assert toString kpatchBuild == builder.kpatchBuild;
      assert targetBuild == realConfiguredTarget.targetBuild;
      modulePackage
      // {
        inherit batch;
        kernelTarget = batch.kernelTarget;
        manifest = batch.manifest;
        targetIdentity = targetBuild.identity;
      };
  };
  successorDescriptor = descriptor // {
    release = "6.12.113.2";
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
    release = "6.12.113.3";
    lineage = successorDescriptor.lineage // {
      predecessorBatch = {
        release = "6.12.113.2";
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
      kernelVersion ? "6.12.117",
      kernelPackage ? mkKernel kernelVersion "${lib.replaceStrings [ "." ] [ "-" ] kernelVersion}",
      livepatchTest ? null,
    }:
    (lib.evalModules {
      specialArgs = mkSpecialArgs livepatchTest;
      modules = [
        ../default.nix
        {
          options = {
            boot.kernelPackage = lib.mkOption { type = lib.types.attrs; };
            boot.kernelVersion = lib.mkOption { type = lib.types.str; };
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
          };
          config = {
            boot = {
              inherit kernelPackage;
              inherit kernelVersion;
              zfsBuiltin = false;
            };
            services.live-patches.enable = true;
          };
        }
      ];
    }).config;
  emptyConfig = evalService { };
  nonTargetConfig = evalService { livepatchTest = syntheticLivepatchTest; };
  legacyConfig = evalService {
    kernelVersion = "6.12.95";
    livepatchTest = syntheticLivepatchTest;
  };
  genericConfig = evalService {
    kernelVersion = "6.12.113";
    kernelPackage = configuredKernel;
    livepatchTest = syntheticLivepatchTest;
  };
  replaceRequestedConfig = evalService {
    kernelVersion = "6.12.113";
    kernelPackage = configuredKernel;
    livepatchTest = mkModuleTest replaceRequestedPackage;
  };
  wrongIdentityConfig = evalService {
    kernelVersion = "6.12.113";
    kernelPackage = configuredKernel;
    livepatchTest = mkModuleTest wrongIdentityPackage;
  };
  mismatchedTargetResult = builtins.tryEval (
    (evalService {
      kernelVersion = "6.12.113";
      kernelPackage = mkKernel "6.12.113" "b";
      livepatchTest = syntheticLivepatchTest;
    }).system.build.livePatchManager.drvPath
  );
  realProductionConfig = evalService {
    kernelVersion = "6.12.113";
    kernelPackage = realKernel;
    livepatchTest = realProductionCallerTest;
  };
  ordinalTwoResult = builtins.tryEval (
    (evalService {
      kernelVersion = "6.12.113";
      kernelPackage = configuredKernel;
      livepatchTest = ordinalTwoTest;
    }).system.build.livePatchManager.drvPath
  );
  gapResult = builtins.tryEval (
    (evalService {
      kernelVersion = "6.12.113";
      kernelPackage = configuredKernel;
      livepatchTest = gapTest;
    }).system.build.livePatchManager.drvPath
  );
  multiReleaseResult = builtins.tryEval (
    (evalService {
      kernelVersion = "6.12.113";
      kernelPackage = configuredKernel;
      livepatchTest = multiReleaseTest;
    }).system.build.livePatchManager.drvPath
  );
in

assert serviceModuleArgs ? specialArgs;
assert !(serviceModuleArgs ? livepatchTest);
assert !(mkSpecialArgs null ? livepatchTest);
assert (mkSpecialArgs syntheticLivepatchTest).livepatchTest == syntheticLivepatchTest;
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
assert !(emptyConfig.system.build ? livePatchModules);
assert !(emptyConfig.system.build ? livePatchManager);
assert !(emptyConfig.environment.etc ? "vpsadminos/livepatch-monitor.json");
assert emptyConfig.runit.services.live-patches.run == "sleep inf";
assert emptyConfig.runit.services.live-patches.finish == "";
assert !(nonTargetConfig.system.build ? livePatchModules);
assert !(nonTargetConfig.system.build ? livePatchManager);
assert !(nonTargetConfig.environment.etc ? "vpsadminos/livepatch-monitor.json");
assert nonTargetConfig.runit.services.live-patches.run == "sleep inf";
assert nonTargetConfig.runit.services.live-patches.finish == "";
assert !(legacyConfig.system.build ? livePatchModules);
assert !(legacyConfig.system.build ? livePatchManager);
assert legacyConfig.system.build ? livePatches;
assert legacyConfig.runit.services.live-patches.run == "live-patches load && sleep inf";
assert legacyConfig.runit.services.live-patches.finish == "live-patches unload";
assert
  (builtins.fromJSON (
    builtins.unsafeDiscardStringContext
      legacyConfig.environment.etc."vpsadminos/livepatch-monitor.json".text
  )).module != moduleName;
assert genericConfig.runit.services.live-patches.run == "sleep inf";
assert genericConfig.runit.services.live-patches.finish == "";
assert genericConfig.environment.etc."vpsadminos/livepatch-monitor.json".text != "";
assert genericConfig.system.build.livePatchModules."6.12.113.1" == modulePackage;
assert !mismatchedTargetResult.success;
assert !ordinalTwoResult.success;
assert !gapResult.success;
assert !multiReleaseResult.success;
assert
  realProductionConfig.system.build.livePatchModules."6.12.113.1".kernelTarget
  == realConfiguredTarget.kernelTarget;
assert
  realProductionConfig.system.build.livePatchModules."6.12.113.1".targetIdentity
  == realConfiguredTarget.targetBuild.identity;
assert
  (builtins.fromJSON (
    builtins.unsafeDiscardStringContext
      genericConfig.environment.etc."vpsadminos/livepatch-monitor.json".text
  )).patchVersion == 1;
assert batch.mode == "additive";
assert batch.unameLevel.protocol == "vpsadminos-additive-uname-v1";
assert batch.unameLevel.releaseOrdinal == 1;
assert batch.unameLevel.predecessorOrdinal == null;
assert batch.unameLevel.rollbackRelease == "6.12.113";
assert batch.unameLevel.publishedRelease == "6.12.113.1";
assert builtins.length batch.build.expected.callbacks == 3;
assert builtins.length batch.build.expected.states == 1;
pkgs.runCommand "livepatch-scalar-manager-unit" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  empty_manager=${lib.escapeShellArg "${builtins.head emptyConfig.environment.systemPackages}/bin/live-patches"}
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
  touch "$out"
''
