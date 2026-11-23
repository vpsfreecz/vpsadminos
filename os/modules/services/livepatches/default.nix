{
  config,
  lib,
  pkgs,
  specialArgs,
  utils,
  ...
}:
with lib;

let
  # Keep the private fixture out of the module's formal arguments: the module
  # resolver treats every declared argument as required in production.
  livepatchTest = specialArgs.livepatchTest or null;
  cfg = config.services.live-patches;
  zfsBuiltinPkg = if config.boot.zfsBuiltin then config.boot.zfsBuiltinPkg else null;
  patchesDir = ../../../livepatches;
  availablePatches = import (patchesDir + /available-patches.nix) {
    inherit lib;
    version = config.boot.kernelVersion;
  };
  availablePatchesList = availablePatches.patchList;
  availablePatchTargets = availablePatches.patchTargets;
  patchVersion = availablePatches.patchVersion;

  buildEnable = (patchVersion > 0) && cfg.enable;

  kernel = config.boot.kernelPackage;
  kpatch-build = pkgs.callPackage (import ../../../packages/kpatch-build/default.nix) { };

  livepatchLib = import ../../../livepatches/lib.nix { inherit lib; };
  registeredCatalog =
    if livepatchTest == null then
      import (patchesDir + /batches) { inherit lib; }
    else
      livepatchTest.catalog;
  configuredCatalog = filter (
    unit:
    unit.batch.kernelVersion == config.boot.kernelVersion
    && unit.batch.kernelVersion == kernel.modDirVersion
  ) registeredCatalog;
  selectedCatalog = configuredCatalog;
  genericKpatchBuild = if livepatchTest == null then kpatch-build else livepatchTest.kpatchBuild;
  genericBuilder =
    if livepatchTest == null then
      {
        kpatchBuild = toString genericKpatchBuild;
        kpatchRevision = kpatch-build.src.rev or "bea635fbbeb11c5f0f5c0d4ffce34c2e9d2e8a6a";
      }
    else
      livepatchTest.builder;
  configuredTarget =
    if selectedCatalog == [ ] then
      null
    else
      livepatchLib.mkConfiguredTarget {
        inherit kernel zfsBuiltinPkg;
        kernelVersion = config.boot.kernelVersion;
        toolchain = kernel.stdenv.cc;
      };
  normalizedGenericCatalog =
    if configuredTarget == null then
      [ ]
    else
      livepatchLib.normalizeCatalog {
        builder = genericBuilder;
        catalog = selectedCatalog;
        target = configuredTarget.kernelTarget;
      };
  livepatchModule =
    if livepatchTest == null then
      pkgs.callPackage ../../../packages/livepatch-module/default.nix { }
    else
      livepatchTest.livepatchModule;
  genericDeployments = imap0 (
    index: catalogEntry:
    let
      batch = catalogEntry.batch;
      module = livepatchModule {
        inherit batch;
        kpatchBuild = genericKpatchBuild;
        targetBuild = configuredTarget.targetBuild;
      };
      expectedOrdinal = index + 1;
    in
    assert batch.unameLevel.releaseOrdinal == expectedOrdinal;
    assert batch.unameLevel.protocol == "vpsadminos-additive-uname-v1";
    assert batch.unameLevel.predecessorOrdinal == (if index == 0 then null else index);
    assert
      batch.unameLevel.rollbackRelease == (
        if index == 0 then
          batch.kernelTarget.kernelVersion
        else
          "${batch.kernelTarget.kernelVersion}.${toString index}"
      );
    assert batch.mode == "additive";
    assert batch.lineage.depth == index;
    assert (batch.lineage.predecessorBatch == null) == (index == 0);
    assert module.batch == batch;
    assert module.manifest == batch.manifest;
    assert module.kernelTarget == configuredTarget.kernelTarget;
    assert module.targetIdentity == configuredTarget.targetBuild.identity;
    assert module.batch.kernelTarget == configuredTarget.kernelTarget;
    assert module.batch.kernelTarget.identity == configuredTarget.targetBuild.identity;
    {
      inherit batch catalogEntry module;
      expectedManifest = pkgs.writeText "${batch.moduleName}-runtime-manifest.json" (
        builtins.toJSON batch.manifest
      );
    }
  ) normalizedGenericCatalog;
  genericBatches = map (deployment: deployment.batch) genericDeployments;
  genericModulePackages = map (deployment: deployment.module) genericDeployments;
  genericBuildEnable = genericDeployments != [ ] && cfg.enable;

  patchName = "${toString patchVersion}";
  patchModuleName = "livepatch_${toString patchVersion}";
  installModDir = "lib/modules/${kernel.modDirVersion}/extra";
  installModPath = "${installModDir}/${patchModuleName}.ko";

  # The running boot kernel exposes this section, including its build ID.
  # Uname alone does not identify a same-version kernel rebuild.
  kernelNotes =
    pkgs.runCommand "livepatch-kernel-notes-${kernel.modDirVersion}"
      {
        nativeBuildInputs = [ pkgs.buildPackages.binutils ];
      }
      ''
        objcopy -O binary --only-section=.notes ${kernel.dev}/vmlinux "$out"
        test -s "$out"
      '';

  genericRuntime =
    if livepatchTest != null then
      livepatchTest.runtime
    else
      {
        appliedDir = "/run/vpsadminos/livepatches";
        date = "${pkgs.coreutils}/bin/date";
        disable = pkgs.writeShellScript "livepatch-disable" ''
          printf '0\n' > "$1"
        '';
        insmod = "${pkgs.kmod}/bin/insmod";
        livepatchRoot = "/sys/kernel/livepatch";
        lockFile = "/run/lock/vpsadminos-livepatch";
        modulesRoot = "/lib/modules";
        bootedModulesTree = "/run/booted-system/kernel-modules";
        storeRoot = "/nix/store";
        pollAttempts = 60;
        pollInterval = "1";
        rmmod = "${pkgs.kmod}/bin/rmmod";
        sysModuleRoot = "/sys/module";
        uname = "${pkgs.coreutils}/bin/uname";
      };
  genericKernelImage =
    if livepatchTest == null then "${kernel}/bzImage" else livepatchTest.kernelImage;
  genericKernelNotes = if livepatchTest == null then kernelNotes else livepatchTest.kernelNotes;

  buildLivePatch =
    {
      availablePatchesList,
      availablePatchSources,
      availablePatchTargets,
      stdenv,
    }:
    stdenv.mkDerivation rec {
      name = "${patchModuleName}-${kernel.modDirVersion}";
      version = toString patchVersion;
      dontUnpack = true;

      hardeningDisable = [
        "bindnow"
        "format"
        "fortify"
        "stackprotector"
        "pic"
      ];
      # ELF tools do not recognize SHF_RELA_LIVEPATCH relocation sections.
      # Stripping can therefore renumber .symtab without updating the symbol
      # indices stored in those sections, corrupting the module at load time.
      dontStrip = true;
      depsBuildBuild = [ pkgs.stdenv.cc ];

      buildPhase = ''
        # Retain kpatch's object-pair temp tree and build.log until installPhase
        # copies the existing evidence set.  DEBUG=0 deletes both on success.
        export DEBUG=1

        # Boot-line toolchain lock (agent0 :324/:328/:340): kpatch-build resolves
        # gcc/ld/readelf/objcopy via PATH, so the kpatch-build invocation below is run
        # with the boot-line gcc-wrapper-15.2.0 prefixed to PATH. The override is scoped
        # to that command only: a buildPhase-wide PATH/CC override broke the ZFS builtin
        # prep's kernel test compile (build #4), while this scope keeps the compiler
        # check and the kernel compile kpatch-build drives on the boot-line toolchain.

        # prepare kpatch-build and its environment
        export CCACHE_UMASK=007
        export CCACHE_DIR=/nix/var/cache/ccache
        export CACHEDIR=$(pwd)/tmp/cache
        # kpatch-build internally sets TEMPDIR="$CACHEDIR/tmp"; use the
        # same path when retaining objects in the existing installPhase.
        export TEMPDIR=$CACHEDIR/tmp
        echo copying kpatch-build locally
        cp -r ${kpatch-build} kpatch-build
        kpb=$(pwd)/kpatch-build
        mkdir -p $TEMPDIR
        mkdir -p $CACHEDIR

        # unpack kernel and detect unpacked folder into $sourceRoot
        local dirsBefore=""
        for i in *; do
            if [ -d "$i" ]; then
                dirsBefore="$dirsBefore $i "
            fi
        done
        echo unpacking ${kernel.src}
        tar xf ${kernel.src}
        sourceRoot=
        for i in *; do
            if [ -d "$i" ]; then
                case $dirsBefore in
                    *\ $i\ *)
                        ;;
                    *)
                        if [ -n "$sourceRoot" ]; then
                            echo "unpacker produced multiple directories"
                            exit 1
                        fi
                        sourceRoot="$i"
                        ;;
                esac
            fi
        done

        # prepare kernel source at src/
        # with ./vmlinux (from kernel.dev) and .config
        mv $sourceRoot src
        export KERNEL_SRCDIR=$(pwd)/src
        # Store-backed source archives may preserve read-only permissions.
        chmod -R u+w src
        cp -r ${kernel.dev}/. ./src/
        chmod -R u+w src
        ln -snf ${kernel.configfile.outPath} ./src/.config

        echo patchShebangs src/scripts
        patchShebangs src/scripts > /dev/null

        # kpatch-build needs the whole env to be writeable, even the stuff
        # we just unpacked and copied
        chmod u+w . -R
      ''
      + optionalString (zfsBuiltinPkg != null) ''
        echo "Copying ZFS builtin package..."
        cp -r ${zfsBuiltinPkg} ./zfsBuiltin
        chmod -R u+w ./zfsBuiltin
        pushd ./zfsBuiltin
        ./copy-builtin ../src
        popd
      ''
      + ''
                cat > src/include/linux/vpsadminos-livepatch-build.h <<LIVEPATCH_HEADER_END
        #ifndef VPSADMINOS_LIVEPATCH_BUILD_H
        #define VPSADMINOS_LIVEPATCH_BUILD_H
        #define LIVEPATCH_ORIG_KERNEL_VERSION        "${kernel.modDirVersion}"
        #define LIVEPATCH_NAME                       "${patchName}"
        #endif
        LIVEPATCH_HEADER_END

                # command preview:
                echo kpatch-build -n ${patchModuleName} ''
      + concatMapStrings (target: "-t ${escapeShellArg target} ") availablePatchTargets
      + concatMapStringsSep " " (name: "${name}.patch") availablePatchesList
      + ''
        ; # we dont get a newline between this and the next line; wtf
                # actual command
                #export ARCH_KCFLAGS="-gz=none"
                if ! $kpb/kpatch-build/kpatch-build -v ${kernel.dev}/vmlinux -s src -n ${patchModuleName} ''
      + concatMapStrings (target: "-t ${escapeShellArg target} ") availablePatchTargets
      + concatMapStringsSep " " (path: escapeShellArg "${path}") availablePatchSources
      + ''
        ; then
          cat $CACHEDIR/build.log || echo log not found at $CACHEDIR/build.log
          exit 1
        fi
      '';

      nativeBuildInputs = kernel.nativeBuildInputs;

      installPhase = ''
        mkdir -p $out/${installModDir};
        cp ${patchModuleName}.ko $out/${installModPath} || (ls -lah && exit 1)

        # The Nix sandbox is removed after a successful build; retain the
        # decisive kpatch object-level evidence in the output.
        mkdir -p $out/livepatch-evidence/diff-objects
        cp $CACHEDIR/build.log $out/livepatch-evidence/build.log 2>/dev/null || echo 'build.log not found' > $out/livepatch-evidence/build.log
        ( cd $CACHEDIR && find . -maxdepth 4 -print | sort ) > $out/livepatch-evidence/cachedir-tree.txt 2>&1 || true
        ( cd $TEMPDIR && find . -maxdepth 4 -print | sort ) > $out/livepatch-evidence/tempdir-tree.txt 2>&1 || true
        ( cd $TEMPDIR && find . -maxdepth 6 \( -name '*.log' -o -name '*.txt' -o -name 'diff-object*' \) -print | sort | head -400 ) > $out/livepatch-evidence/diff-object-files.txt 2>&1 || true
        ( cd $TEMPDIR && find . -maxdepth 6 \( -name '*.log' -o -name '*.txt' -o -name 'diff-object*' \) -print | sort | head -200 | while read -r f; do cp --parents "$f" $out/livepatch-evidence/diff-objects/ 2>/dev/null; done ) || true
      '';
    };

  patches = pkgs.callPackage buildLivePatch {
    inherit availablePatchesList availablePatchTargets;
    availablePatchSources = availablePatches.patchSources;
  };

  moduleLoadGen =
    { moduleName, installModPath }:
    let
      modDetectDir = "/sys/kernel/livepatch/${moduleName}";
    in
    ''
      if [ ! -d ${modDetectDir} ]; then
        echo live-patches: loading and applying ${moduleName}...
        if ! insmod ${installModPath}; then
          echo live-patches: loading and applying ${moduleName} FAILED >&2
          exit 1
        fi
      fi
      if [ -f ${modDetectDir}/enabled ] && [ "$(cat ${modDetectDir}/enabled 2>/dev/null)" = "1" ]; then
        mkdir -p /run/vpsadminos/livepatches
        if [ ! -e /run/vpsadminos/livepatches/${moduleName}.applied-at ]; then
          date --utc +%Y-%m-%dT%H:%M:%SZ \
            > /run/vpsadminos/livepatches/${moduleName}.applied-at
        fi
      else
        echo live-patches: ${moduleName} is not enabled >&2
        exit 1
      fi
    '';

  moduleUnloadGen =
    { moduleName }:
    let
      modDetectDir = "/sys/kernel/livepatch/${moduleName}";
    in
    ''
      if [ -d ${modDetectDir} ] && [ -f ${modDetectDir}/enabled ]; then
        echo -en live-patches: disabling ${moduleName}..
        enabled_state=$(cat ${modDetectDir}/enabled 2>/dev/null) || {
          echo -e "\nlive-patches: reading ${moduleName} state FAILED" >&2
          exit 1
        }
        case "$enabled_state" in
          1)
            if ! echo 0 > ${modDetectDir}/enabled 2>/dev/null; then
              echo -e "\nlive-patches: disabling ${moduleName} FAILED" >&2
              exit 1
            fi
            ;;
          0) ;; # Already disabled: a repeated write is rejected by livepatch.
          *)
            echo -e "\nlive-patches: invalid ${moduleName} state" >&2
            exit 1
            ;;
        esac
        retries=91
        while [ -d ${modDetectDir} ] && [ $retries -gt 0 ]; do
          if [ "$(( $retries % 5 ))" -eq 0 ]; then
            echo -en " $retries "
          fi
          transition=$(cat ${modDetectDir}/transition 2>/dev/null)
          if [ "$transition" -eq 1 ] 2>/dev/null; then
            echo -en .
          else
            echo -en ?
          fi
          retries=$(( $retries - 1 ))
          sleep 1
        done
        echo
      fi
      retries=13
      if [ -d /sys/module/${moduleName} ]; then
        echo -en live-patches: unloading ${moduleName}..
        while [ -d /sys/module/${moduleName} ] && [ $retries -gt 0 ]; do
          if [ "$(( $retries % 3 ))" -eq 0 ]; then
            echo -en " $retries "
          fi
          echo -en .
          retries=$(( $retries - 1 ))
          if ! rmmod ${moduleName} 2>/dev/null; then
            sleep 0.2
          fi
        done
        echo
      fi
      if [ -d /sys/module/${moduleName} ] || [ -d ${modDetectDir} ]; then
        echo live-patches: unloading ${moduleName} FAILED >&2
        exit 1
      fi
      rm -f /run/vpsadminos/livepatches/${moduleName}.applied-at
    '';

  moduleListGen =
    { moduleName }:
    let
      modDetectDir = "/sys/kernel/livepatch/${moduleName}";
    in
    ''
      s="["
      if [ -d /sys/module/${moduleName} ]; then
        s="$s loaded";
        if [ -f ${modDetectDir}/enabled ] && \
           [ "$(cat ${modDetectDir}/enabled 2>/dev/null)" == "1" ]; then
          s="$s enabled"
        fi
        if [ "$(cat ${modDetectDir}/transition 2>/dev/null)" == "1" ]; then
          s="$s transition"
        fi
      else
        s="$s unloaded"
      fi
      printf "%-27s%s\n" "$s" " ] ${moduleName}"
    '';

  moduleStatusGen =
    { moduleName }:
    moduleListGen { inherit moduleName; }
    + foldl (x: y: "${x}\n${y}") "\n" (
      map (
        patch:
        let
          pVer = availablePatches.getPatchVersion patch;
        in
        "printf '%29s %s\n' 'contains:' '${patch.name}"
        + optionalString (pVer > 1) "(v${toString pVer})"
        + "'"
      ) availablePatches.filteredPatches
    );

  moduleLoadContent = ''
    livepatch=$(cat /etc/livepatch-store-path)
    mkdir -p /lib/modules
    ln -snf /run/current-system/kernel-modules/lib/modules/${kernel.modDirVersion} /lib/modules/${kernel.modDirVersion}.${patchName}
  ''
  + moduleLoadGen {
    installModPath = "$livepatch/${installModPath}";
    moduleName = patchModuleName;
  }
  + "";

  moduleUnloadContent = ''
    livepatch=$(cat /etc/livepatch-store-path)
    # Patches built with build-kpatch
  ''
  + moduleUnloadGen { moduleName = patchModuleName; }
  + "\n";

  moduleListContent = ''
    livepatch=$(cat /etc/livepatch-store-path)
  ''
  + moduleListGen { moduleName = patchModuleName; }
  + "\n";

  moduleStatusContent = ''
    livepatch=$(cat /etc/livepatch-store-path)
  ''
  + moduleStatusGen { moduleName = patchModuleName; }
  + "\n";

  genericSelectCases = concatMapStringsSep "\n" (
    deployment:
    let
      batch = deployment.batch;
      moduleFile = "${deployment.module}/${batch.installPath}";
      evidenceDir = "${deployment.module}/share/vpsadminos-livepatch";
    in
    ''
      ${toString batch.unameLevel.releaseOrdinal})
        batch_release=${escapeShellArg batch.release}
        batch_ordinal=${escapeShellArg (toString batch.unameLevel.releaseOrdinal)}
        module_name=${escapeShellArg batch.moduleName}
        module_file=${escapeShellArg moduleFile}
        evidence_dir=${escapeShellArg evidenceDir}
        expected_manifest=${escapeShellArg deployment.expectedManifest}
        published_release=${escapeShellArg batch.unameLevel.publishedRelease}
        rollback_release=${escapeShellArg batch.unameLevel.rollbackRelease}
        patch_dir=${escapeShellArg "${genericRuntime.livepatchRoot}/${batch.moduleName}"}
        sys_module_dir=${escapeShellArg "${genericRuntime.sysModuleRoot}/${batch.moduleName}"}
        applied_marker=${escapeShellArg "${genericRuntime.appliedDir}/${batch.moduleName}.applied-at"}
        release_link=${escapeShellArg "${genericRuntime.modulesRoot}/${batch.unameLevel.publishedRelease}"}
        ;;
    ''
  ) genericDeployments;
  genericConfiguredNameCases = concatMapStringsSep "\n" (
    deployment: "${escapeShellArg deployment.batch.moduleName}) return 0 ;;"
  ) genericDeployments;
  genericCoverageCases = concatMapStringsSep "\n" (
    deployment:
    let
      batch = deployment.batch;
      objects = unique (map (function: function.object) batch.build.expected.functions);
      objectChecks = concatMapStringsSep "\n" (object: ''
        object_state=$(read_boolean "$patch_dir/${object}/patched") || {
          object_result=$?
          return "$object_result"
        }
        if [ "$object_state" != 1 ]; then
          echo "live-patches: target object ${object} is not patched for $module_name" >&2
          return "$authority_disagreement"
        fi
      '') objects;
      functionChecks = concatMapStringsSep "\n" (
        function:
        let
          sysfsSympos = if function.sympos == 0 then 1 else function.sympos;
        in
        ''
          if [ ! -d "$patch_dir/${function.object}/${function.symbol},${toString sysfsSympos}" ]; then
            echo "live-patches: target function ${function.object}:${function.symbol}:${toString function.sympos} is missing for $module_name" >&2
            return "$authority_disagreement"
          fi
        ''
      ) batch.build.expected.functions;
    in
    ''
      ${toString batch.unameLevel.releaseOrdinal})
        ${objectChecks}
        ${functionChecks}
        ;;
    ''
  ) genericDeployments;
  genericConfiguredOrdinals = concatStringsSep " " (
    map (deployment: toString deployment.batch.unameLevel.releaseOrdinal) genericDeployments
  );

  genericLivePatchesContent = optionalString genericBuildEnable ''
    configured_count=${toString (length genericDeployments)}
    configured_ordinals=${escapeShellArg genericConfiguredOrdinals}
    booted_modules_tree=${escapeShellArg genericRuntime.bootedModulesTree}
    native_mod_dir=${escapeShellArg kernel.modDirVersion}
    store_root=${escapeShellArg genericRuntime.storeRoot}
    module_tree=
    inventory_error=0
    authority_disagreement=1
    authority_collection_error=2

    usage() {
      echo "usage: $0 load [N]|unload [N]|list|status" >&2
      return 1
    }

    valid_ordinal() {
      case "$1" in
        0|*[!0-9]*|0*) return 1 ;;
        *) [ "$1" -le "$configured_count" ] ;;
      esac
    }

    select_batch() {
      case "$1" in
        ${genericSelectCases}
        *)
          echo "live-patches: ordinal $1 is not configured" >&2
          return 1
          ;;
      esac
    }

    configured_name() {
      case "$1" in
        ${genericConfiguredNameCases}
        *) return 1 ;;
      esac
    }

    state_or_missing() {
      if [ -f "$1" ]; then
        ${pkgs.coreutils}/bin/cat "$1" 2>/dev/null || printf unreadable
      else
        printf missing
      fi
    }

    report_state() {
      enabled_state=$(state_or_missing "$patch_dir/enabled")
      transition_state=$(state_or_missing "$patch_dir/transition")
      replace_state=$(state_or_missing "$patch_dir/replace")
      current_release=$(${genericRuntime.uname} -r 2>/dev/null || printf unreadable)
      echo "live-patches: release=$batch_release ordinal=$batch_ordinal expected-release=$published_release current-release=$current_release" >&2
      echo "live-patches: $module_name state enabled=$enabled_state transition=$transition_state replace=$replace_state" >&2
    }

    read_boolean() {
      if [ ! -f "$1" ]; then
        echo "live-patches: missing state file $1" >&2
        return "$authority_collection_error"
      fi
      value=$(${pkgs.coreutils}/bin/cat "$1" 2>/dev/null) || {
        echo "live-patches: cannot read state file $1" >&2
        return "$authority_collection_error"
      }
      case "$value" in
        0|1) printf '%s' "$value" ;;
        *)
          echo "live-patches: invalid boolean state in $1: $value" >&2
          return "$authority_collection_error"
          ;;
      esac
    }

    check_release() {
      expected_release="$1"
      context="$2"
      current_release=$(${genericRuntime.uname} -r 2>/dev/null) || {
        echo "live-patches: cannot read uname release during $context" >&2
        return "$authority_collection_error"
      }
      if [ "$current_release" != "$expected_release" ]; then
        echo "live-patches: uname release $current_release does not match expected $expected_release during $context" >&2
        return "$authority_disagreement"
      fi
    }

    check_module_identity() {
      if [ ! -f "$module_file" ] || \
         [ ! -f "$evidence_dir/manifest.json" ] || \
         [ ! -f "$evidence_dir/inspection.json" ] || \
         [ ! -f "$evidence_dir/closure.json" ]; then
        echo "live-patches: $module_name module evidence is incomplete" >&2
        return "$authority_disagreement"
      fi
      if ${pkgs.diffutils}/bin/cmp -s "$expected_manifest" "$evidence_dir/manifest.json"; then
        :
      else
        compare_result=$?
        if [ "$compare_result" -eq 1 ]; then
          echo "live-patches: $module_name manifest identity mismatch" >&2
          return "$authority_disagreement"
        fi
        echo "live-patches: cannot compare $module_name manifest evidence" >&2
        return "$authority_collection_error"
      fi
      if ${pkgs.jq}/bin/jq -e '.matches == true' \
        "$evidence_dir/closure.json" >/dev/null 2>&1; then
        :
      else
        jq_result=$?
        if [ "$jq_result" -eq 1 ]; then
          echo "live-patches: $module_name closure evidence is not successful" >&2
          return "$authority_disagreement"
        fi
        echo "live-patches: cannot read or parse closure evidence for $module_name" >&2
        return "$authority_collection_error"
      fi
      if ${pkgs.jq}/bin/jq -e \
        '.buildInvocation == { flags: ["--non-replace"], nonReplaceRequested: true }' \
        "$evidence_dir/inspection.json" >/dev/null 2>&1; then
        :
      else
        jq_result=$?
        if [ "$jq_result" -eq 1 ]; then
          echo "live-patches: $module_name was not built in additive mode" >&2
          return "$authority_disagreement"
        fi
        echo "live-patches: cannot read or parse inspection evidence for $module_name" >&2
        return "$authority_collection_error"
      fi
      inspection_name=$(${pkgs.jq}/bin/jq -er \
        '.module.name' "$evidence_dir/inspection.json" 2>/dev/null) || {
        echo "live-patches: cannot read or parse inspection evidence for $module_name" >&2
        return "$authority_collection_error"
      }
      expected_sha=$(${pkgs.jq}/bin/jq -er \
        '.module.sha256 | select(type == "string" and test("^[0-9a-f]{64}$"))' \
        "$evidence_dir/inspection.json" 2>/dev/null) || {
        echo "live-patches: cannot read or parse inspection evidence for $module_name" >&2
        return "$authority_collection_error"
      }
      hash_line=$(${pkgs.coreutils}/bin/sha256sum "$module_file" 2>/dev/null) || {
        echo "live-patches: cannot hash configured module $module_file" >&2
        return "$authority_collection_error"
      }
      actual_sha="''${hash_line%% *}"
      if [ "$inspection_name" != "$module_name" ] || \
         [ "$actual_sha" != "$expected_sha" ]; then
        echo "live-patches: $module_name module identity mismatch" >&2
        return "$authority_disagreement"
      fi
    }

    resolve_module_tree() {
      booted_tree_resolved=$(${pkgs.coreutils}/bin/readlink -f "$booted_modules_tree" 2>/dev/null) || {
        echo "live-patches: cannot resolve booted module-tree authority $booted_modules_tree" >&2
        return "$authority_collection_error"
      }
      case "$booted_tree_resolved" in
        "$store_root"/*) ;;
        *)
          echo "live-patches: booted module-tree authority is not an immutable store path" >&2
          return "$authority_disagreement"
          ;;
      esac

      native_tree="$booted_tree_resolved/lib/modules/$native_mod_dir"
      if [ ! -d "$native_tree" ]; then
        echo "live-patches: native module tree $native_tree is missing" >&2
        return "$authority_disagreement"
      fi
      module_tree=$(${pkgs.coreutils}/bin/readlink -f "$native_tree" 2>/dev/null) || {
        echo "live-patches: cannot resolve native module tree $native_tree" >&2
        return "$authority_collection_error"
      }
      case "$module_tree" in
        "$store_root"/*) ;;
        *)
          echo "live-patches: native module tree does not resolve into the immutable store" >&2
          return "$authority_disagreement"
          ;;
      esac
    }

    verify_release_link() {
      resolve_module_tree || {
        resolve_result=$?
        return "$resolve_result"
      }
      if [ ! -L "$release_link" ]; then
        echo "live-patches: module-tree path $release_link is not the owned symlink" >&2
        return "$authority_disagreement"
      fi
      link_target=$(${pkgs.coreutils}/bin/readlink "$release_link" 2>/dev/null) || {
        echo "live-patches: cannot read module-tree symlink $release_link" >&2
        return "$authority_collection_error"
      }
      if [ "$link_target" != "$module_tree" ]; then
        echo "live-patches: module-tree symlink $release_link is not owned by this batch" >&2
        return "$authority_disagreement"
      fi
      resolved_link=$(${pkgs.coreutils}/bin/readlink -f "$release_link" 2>/dev/null) || {
        echo "live-patches: cannot resolve module-tree symlink $release_link" >&2
        return "$authority_collection_error"
      }
      if [ "$resolved_link" != "$module_tree" ]; then
        echo "live-patches: resolved module-tree symlink $release_link is not owned by this batch" >&2
        return "$authority_disagreement"
      fi
    }

    ensure_release_link() {
      resolve_module_tree || return 1
      if [ -e "$release_link" ] || [ -L "$release_link" ]; then
        verify_release_link
        return
      fi
      if [ ! -d "$module_tree" ]; then
        echo "live-patches: native module tree $module_tree is missing" >&2
        return 1
      fi
      ${pkgs.coreutils}/bin/mkdir -p ${escapeShellArg genericRuntime.modulesRoot}
      if ! ${pkgs.coreutils}/bin/ln -s -- "$module_tree" "$release_link"; then
        echo "live-patches: cannot create module-tree symlink $release_link" >&2
        return 1
      fi
      verify_release_link
    }

    remove_release_link() {
      verify_release_link || return 1
      if ! ${pkgs.coreutils}/bin/rm -- "$release_link"; then
        echo "live-patches: cannot remove owned module-tree symlink $release_link" >&2
        return 1
      fi
    }

    read_runtime_state() {
      if [ ! -d "$patch_dir" ]; then
        echo "live-patches: missing livepatch state directory $patch_dir" >&2
        return 1
      fi
      enabled_state=$(read_boolean "$patch_dir/enabled") || return 1
      transition_state=$(read_boolean "$patch_dir/transition") || return 1
      replace_state=$(read_boolean "$patch_dir/replace") || return 1
    }

    verify_coverage() {
      case "$batch_ordinal" in
        ${genericCoverageCases}
        *) return 1 ;;
      esac
    }

    publish_applied() {
      if [ -e "$applied_marker" ]; then
        if [ ! -f "$applied_marker" ]; then
        echo "live-patches: applied marker $applied_marker is not a regular file" >&2
          return 1
        fi
        return 0
      fi
      ${pkgs.coreutils}/bin/mkdir -p ${escapeShellArg genericRuntime.appliedDir}
      marker_tmp="$applied_marker.tmp.$$"
      if ! ${genericRuntime.date} --utc +%Y-%m-%dT%H:%M:%SZ > "$marker_tmp"; then
        ${pkgs.coreutils}/bin/rm -f "$marker_tmp"
        echo "live-patches: cannot record $module_name application time" >&2
        return 1
      fi
      ${pkgs.coreutils}/bin/mv "$marker_tmp" "$applied_marker"
    }

    classify_batch() {
      phase=inconsistent
      patch_present=0
      module_present=0
      marker_present=0
      link_present=0

      [ -d "$patch_dir" ] && patch_present=1
      [ -d "$sys_module_dir" ] && module_present=1
      if [ -e "$applied_marker" ] || [ -L "$applied_marker" ]; then
        [ -f "$applied_marker" ] || return 0
        marker_present=1
      fi
      if [ -e "$release_link" ] || [ -L "$release_link" ]; then
        link_present=1
      fi

      if [ "$patch_present" = 0 ]; then
        if [ "$module_present" = 0 ] && [ "$marker_present" = 0 ] && [ "$link_present" = 0 ]; then
          phase=absent
        elif [ "$module_present" = 1 ] && [ "$marker_present" = 1 ] && [ "$link_present" = 1 ]; then
          phase=disabled-present
        elif [ "$module_present" = 0 ] && [ "$marker_present" = 1 ] && [ "$link_present" = 1 ]; then
          phase=cleanup-pending
        fi
        return 0
      fi

      [ "$module_present" = 1 ] && [ "$link_present" = 1 ] || return 0
      read_runtime_state || return 0
      [ "$replace_state" = 0 ] || return 0
      if [ "$enabled_state" = 1 ] && [ "$transition_state" = 0 ] && [ "$marker_present" = 1 ]; then
        phase=active
      elif [ "$enabled_state" = 1 ] && [ "$transition_state" = 1 ] && [ "$marker_present" = 0 ]; then
        phase=forward-transition
      elif [ "$enabled_state" = 0 ] && [ "$marker_present" = 1 ]; then
        phase=reverse-transition
      fi
    }

    refuse_unknown_runtime() {
      if [ -d ${escapeShellArg genericRuntime.livepatchRoot} ]; then
        for observed in ${escapeShellArg genericRuntime.livepatchRoot}/*; do
          [ -e "$observed" ] || continue
          observed_name="''${observed##*/}"
          if ! configured_name "$observed_name"; then
            echo "live-patches: unsupported livepatch $observed_name is present" >&2
            return 1
          fi
        done
      fi
      if [ -d ${escapeShellArg genericRuntime.appliedDir} ]; then
        for marker in ${escapeShellArg genericRuntime.appliedDir}/*.applied-at; do
          [ -e "$marker" ] || [ -L "$marker" ] || continue
          marker_file="''${marker##*/}"
          observed_name="''${marker_file%.applied-at}"
          if [ -d "${genericRuntime.sysModuleRoot}/$observed_name" ] && \
             ! configured_name "$observed_name"; then
            echo "live-patches: manager-owned module $observed_name is not configured" >&2
            return 1
          fi
        done
      fi
    }

    scan_stack() {
      refuse_unknown_runtime || return 1
      active_tip=0
      pending_ordinal=0
      pending_phase=
      seen_non_active=0

      for ordinal in $configured_ordinals; do
        select_batch "$ordinal" || return 1
        check_module_identity || return 1
        classify_batch
        case "$phase" in
          active)
            if [ "$seen_non_active" = 1 ]; then
              echo "live-patches: configured stack contains a gap before ordinal $ordinal" >&2
              return 1
            fi
            verify_coverage || return 1
            verify_release_link || return 1
            active_tip=$ordinal
            ;;
          absent)
            seen_non_active=1
            ;;
          forward-transition|reverse-transition|disabled-present|cleanup-pending)
            if [ "$seen_non_active" = 1 ] || [ "$pending_ordinal" != 0 ]; then
              echo "live-patches: configured stack has ambiguous partial state at ordinal $ordinal" >&2
              return 1
            fi
            pending_ordinal=$ordinal
            pending_phase=$phase
            seen_non_active=1
            ;;
          *)
            echo "live-patches: configured stack has inconsistent state at ordinal $ordinal" >&2
            report_state
            return 1
            ;;
        esac
      done

      if [ "$pending_ordinal" = 0 ]; then
        if [ "$active_tip" = 0 ]; then
          expected_release=$native_mod_dir
        else
          select_batch "$active_tip" || return 1
          expected_release=$published_release
        fi
        check_release "$expected_release" "stack preflight" || return 1
      fi
    }

    load_batch() {
      select_batch "$1" || return 1
      check_module_identity || return 1
      classify_batch

      if [ "$phase" = absent ]; then
        check_release "$rollback_release" "load preflight" || return 1
        if [ -e "$applied_marker" ]; then
          echo "live-patches: stale applied marker exists for unloaded $module_name" >&2
          return 1
        fi
        ensure_release_link || return 1
        echo "live-patches: loading and applying $module_name..."
        if ! ${genericRuntime.insmod} "$module_file"; then
          echo "live-patches: loading and applying $module_name FAILED" >&2
          report_state
          return 1
        fi
      elif [ "$phase" = forward-transition ]; then
        ensure_release_link || return 1
      elif [ "$phase" = active ]; then
        return 0
      else
        echo "live-patches: $module_name is not safe to load from state $phase" >&2
        return 1
      fi

      attempt=0
      while [ "$attempt" -lt ${toString genericRuntime.pollAttempts} ]; do
        read_runtime_state || {
          report_state
          return 1
        }
        if [ "$replace_state" != 0 ]; then
          echo "live-patches: $module_name unexpectedly has replace=1" >&2
          report_state
          return 1
        fi
        if [ "$enabled_state" = 1 ] && [ "$transition_state" = 0 ]; then
          verify_coverage || return 1
          check_release "$published_release" "load convergence" || {
            report_state
            return 1
          }
          verify_release_link || return 1
          publish_applied || return 1
          return 0
        fi
        if [ "$enabled_state" != 1 ] || [ "$transition_state" != 1 ]; then
          echo "live-patches: $module_name entered an unexpected state" >&2
          report_state
          return 1
        fi

        attempt=$((attempt + 1))
        if [ "$attempt" -lt ${toString genericRuntime.pollAttempts} ]; then
          ${pkgs.coreutils}/bin/sleep ${escapeShellArg (toString genericRuntime.pollInterval)}
        fi
      done

      echo "live-patches: $module_name did not converge within the activation deadline" >&2
      report_state
      return 1
    }

    finish_unload_cleanup() {
      check_release "$rollback_release" "unload cleanup" || return 1
      if [ ! -f "$applied_marker" ]; then
        echo "live-patches: $module_name has no owned applied marker" >&2
        return 1
      fi

      if [ -d "$sys_module_dir" ]; then
        verify_release_link || return 1
        if ! ${genericRuntime.rmmod} "$module_name"; then
          echo "live-patches: removing $module_name FAILED" >&2
          return 1
        fi
        if [ -d "$sys_module_dir" ]; then
          echo "live-patches: $module_name remains loaded after removal" >&2
          return 1
        fi
      fi

      if [ -e "$release_link" ] || [ -L "$release_link" ]; then
        remove_release_link || return 1
      fi
      if ! ${pkgs.coreutils}/bin/rm -- "$applied_marker"; then
        echo "live-patches: cannot remove $module_name applied marker" >&2
        return 1
      fi
    }

    unload_batch() {
      select_batch "$1" || return 1
      check_module_identity || return 1
      classify_batch

      if [ "$phase" = absent ]; then
        check_release "$rollback_release" "unload no-op" || return 1
        return 0
      elif [ "$phase" = disabled-present ] || [ "$phase" = cleanup-pending ]; then
        verify_release_link || return 1
        finish_unload_cleanup
        return
      elif [ "$phase" != active ] && [ "$phase" != reverse-transition ]; then
        echo "live-patches: $module_name is not safe to unload from state $phase" >&2
        return 1
      fi

      verify_release_link || return 1

      read_runtime_state || {
        report_state
        return 1
      }
      if [ "$replace_state" != 0 ]; then
        echo "live-patches: $module_name unexpectedly has replace=1" >&2
        report_state
        return 1
      fi

      if [ "$enabled_state" = 1 ] && [ "$transition_state" = 0 ]; then
        verify_coverage || return 1
        check_release "$published_release" "unload preflight" || return 1
        if ! ${genericRuntime.disable} "$patch_dir/enabled"; then
          echo "live-patches: disabling $module_name FAILED" >&2
          report_state
          return 1
        fi
      elif [ "$enabled_state" = 0 ] && [ "$transition_state" = 1 ]; then
        : # Resume observation without repeating the disable write.
      elif [ "$enabled_state" = 0 ] && [ "$transition_state" = 0 ]; then
        check_release "$rollback_release" "unload convergence" || return 1
      else
        echo "live-patches: $module_name is not safe to unload" >&2
        report_state
        return 1
      fi

      attempt=0
      while [ "$attempt" -lt ${toString genericRuntime.pollAttempts} ]; do
        if [ ! -d "$patch_dir" ]; then
          check_release "$rollback_release" "unload convergence" || return 1
          break
        fi

        read_runtime_state || {
          report_state
          return 1
        }
        if [ "$replace_state" != 0 ]; then
          echo "live-patches: $module_name unexpectedly has replace=1" >&2
          report_state
          return 1
        fi
        if [ "$enabled_state" != 0 ] || \
           { [ "$transition_state" != 0 ] && [ "$transition_state" != 1 ]; }; then
          echo "live-patches: $module_name entered an unexpected reverse state" >&2
          report_state
          return 1
        fi
        if [ "$transition_state" = 0 ]; then
          check_release "$rollback_release" "unload convergence" || {
            report_state
            return 1
          }
        fi

        attempt=$((attempt + 1))
        if [ "$attempt" -lt ${toString genericRuntime.pollAttempts} ]; then
          ${pkgs.coreutils}/bin/sleep ${escapeShellArg (toString genericRuntime.pollInterval)}
        fi
      done

      if [ -d "$patch_dir" ]; then
        echo "live-patches: $module_name did not finish reverse transition within the deadline" >&2
        report_state
        return 1
      fi
      finish_unload_cleanup
    }

    print_inventory_row() {
      printf 'ordinal=%s release=%s module=%s configured=%s present=%s enabled=%s transition=%s replace=%s state=%s\n' \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
    }

    append_inventory_row() {
      if [ -n "$inventory_rows" ]; then
        inventory_rows="$inventory_rows "
      fi
      inventory_rows="$inventory_rows$1|$2|$3|$4|$5|$6|$7|$8|$9"
    }

    print_inventory_rows() {
      for inventory_row in $inventory_rows; do
        old_ifs=$IFS
        IFS='|'
        set -- $inventory_row
        IFS=$old_ifs
        row_ordinal=$1
        row_release=$2
        row_module=$3
        row_configured=$4
        row_present=$5
        row_enabled=$6
        row_transition=$7
        row_replace=$8
        row_state=$9
        if [ "$inventory_global_disagreement" = 1 ] && \
           [ "$row_configured" = yes ] && [ "$row_state" = active ]; then
          row_state=partial/inconsistent
        fi
        print_inventory_row "$row_ordinal" "$row_release" "$row_module" \
          "$row_configured" "$row_present" "$row_enabled" "$row_transition" \
          "$row_replace" "$row_state"
      done
    }

    inventory_contains() {
      case " $inventory_seen " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
      esac
    }

    inventory_authority() {
      if "$@"; then
        return 0
      else
        authority_result=$?
      fi
      case "$authority_result" in
        "$authority_disagreement") ;;
        "$authority_collection_error") inventory_error=1 ;;
        *)
          echo "live-patches: unexpected inventory authority result $authority_result" >&2
          inventory_error=1
          ;;
      esac
      return 1
    }

    corroborate_active_inventory() {
      state=partial/inconsistent
      if [ ! -d "$sys_module_dir" ]; then
        echo "live-patches: kernel module $module_name is missing during inventory" >&2
        return 0
      fi
      if [ ! -e "$applied_marker" ] && [ ! -L "$applied_marker" ]; then
        echo "live-patches: applied marker $applied_marker is missing during inventory" >&2
        return 0
      fi
      if [ ! -f "$applied_marker" ] || [ -L "$applied_marker" ]; then
        echo "live-patches: applied marker $applied_marker is not a regular owned file" >&2
        return 0
      fi
      inventory_authority check_module_identity || return 0
      inventory_authority verify_coverage || return 0
      inventory_authority verify_release_link || return 0
      state=active
    }

    report_inventory() {
      inventory_error=0
      inventory_seen=
      inventory_rows=
      inventory_prefix_open=1
      inventory_expected_release=$native_mod_dir
      inventory_snapshot_ambiguous=0
      inventory_global_disagreement=0
      for ordinal in $configured_ordinals; do
        select_batch "$ordinal" || return 1
        inventory_seen="$inventory_seen $module_name"
        present=no
        enabled=missing
        transition=missing
        replace=missing
        state=configured-not-loaded
        if [ -d "$patch_dir" ]; then
          present=yes
          if ! enabled=$(read_boolean "$patch_dir/enabled"); then
            enabled=unreadable
            inventory_error=1
          fi
          if ! transition=$(read_boolean "$patch_dir/transition"); then
            transition=unreadable
            inventory_error=1
          fi
          if ! replace=$(read_boolean "$patch_dir/replace"); then
            replace=unreadable
            inventory_error=1
          fi
          if [ "$enabled" = 1 ] && [ "$transition" = 0 ] && [ "$replace" = 0 ]; then
            corroborate_active_inventory
          elif [ "$transition" = 1 ]; then
            state=transitioning
          else
            state=partial/inconsistent
          fi
        elif [ -d "$sys_module_dir" ] && [ -f "$applied_marker" ]; then
          present=yes
          enabled=0
          transition=0
          replace=0
          state=disabled-present
        elif [ ! -d "$sys_module_dir" ] && [ -f "$applied_marker" ] && \
             { [ -e "$release_link" ] || [ -L "$release_link" ]; }; then
          enabled=0
          transition=0
          replace=0
          state=cleanup-pending
        elif [ -d "$sys_module_dir" ] || [ -e "$applied_marker" ] || [ -L "$applied_marker" ] || \
             [ -e "$release_link" ] || [ -L "$release_link" ]; then
          present=yes
          state=partial/inconsistent
        fi

        case "$state" in
          active)
            if [ "$inventory_prefix_open" = 1 ]; then
              inventory_expected_release=$batch_release
            else
              state=partial/inconsistent
              inventory_snapshot_ambiguous=1
            fi
            ;;
          disabled-present|cleanup-pending)
            if [ "$inventory_prefix_open" != 1 ]; then
              state=partial/inconsistent
              inventory_snapshot_ambiguous=1
            fi
            inventory_prefix_open=0
            ;;
          configured-not-loaded)
            inventory_prefix_open=0
            ;;
          transitioning|partial/inconsistent)
            inventory_prefix_open=0
            inventory_snapshot_ambiguous=1
            ;;
        esac

        append_inventory_row "$batch_ordinal" "$batch_release" "$module_name" yes \
          "$present" "$enabled" "$transition" "$replace" "$state"
      done

      if [ -d ${escapeShellArg genericRuntime.livepatchRoot} ]; then
        for observed in ${escapeShellArg genericRuntime.livepatchRoot}/*; do
          [ -e "$observed" ] || continue
          observed_name="''${observed##*/}"
          inventory_contains "$observed_name" && continue
          inventory_seen="$inventory_seen $observed_name"
          if ! enabled=$(read_boolean "$observed/enabled"); then
            enabled=unreadable
            inventory_error=1
          fi
          if ! transition=$(read_boolean "$observed/transition"); then
            transition=unreadable
            inventory_error=1
          fi
          if ! replace=$(read_boolean "$observed/replace"); then
            replace=unreadable
            inventory_error=1
          fi
          if [ "$transition" = 1 ]; then
            state=transitioning
          elif [ "$enabled" = 0 ] || [ "$enabled" = 1 ]; then
            state=loaded-not-configured
          else
            state=metadata-unavailable
          fi
          inventory_snapshot_ambiguous=1
          append_inventory_row unavailable unavailable "$observed_name" no yes \
            "$enabled" "$transition" "$replace" "$state"
        done
      fi

      if [ -d ${escapeShellArg genericRuntime.appliedDir} ]; then
        for marker in ${escapeShellArg genericRuntime.appliedDir}/*.applied-at; do
          [ -e "$marker" ] || [ -L "$marker" ] || continue
          marker_file="''${marker##*/}"
          observed_name="''${marker_file%.applied-at}"
          inventory_contains "$observed_name" && continue
          [ -d "${genericRuntime.sysModuleRoot}/$observed_name" ] || continue
          if [ ! -f "$marker" ] || [ -L "$marker" ]; then
            state=partial/inconsistent
          else
            state=disabled-present
          fi
          inventory_seen="$inventory_seen $observed_name"
          inventory_snapshot_ambiguous=1
          append_inventory_row unavailable unavailable "$observed_name" no yes 0 0 0 "$state"
        done
      fi

      if inventory_current_release=$(${genericRuntime.uname} -r 2>/dev/null); then
        case "$inventory_current_release" in
          ""|*[!0-9A-Za-z._+-]*)
            echo "live-patches: cannot parse uname release during inventory" >&2
            inventory_error=1
            inventory_global_disagreement=1
            ;;
          *)
            if [ "$inventory_snapshot_ambiguous" = 0 ] && \
               [ "$inventory_current_release" != "$inventory_expected_release" ]; then
              echo "live-patches: uname release $inventory_current_release does not match expected $inventory_expected_release during inventory" >&2
              inventory_global_disagreement=1
            fi
            ;;
        esac
      else
        echo "live-patches: cannot read uname release during inventory" >&2
        inventory_error=1
        inventory_global_disagreement=1
      fi

      print_inventory_rows

      if [ "$inventory_error" != 0 ]; then
        echo "live-patches: inventory collection failed; partial results shown" >&2
        return 1
      fi
    }

    lock_manager() {
      ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname ${escapeShellArg genericRuntime.lockFile})"
      exec 9>${escapeShellArg genericRuntime.lockFile}
      ${pkgs.util-linux}/bin/flock -x 9
    }

    load_to_ordinal() {
      target_ordinal="$1"
      scan_stack || return 1
      if [ "$target_ordinal" -le "$active_tip" ]; then
        return 0
      fi
      if [ "$target_ordinal" -ne "$((active_tip + 1))" ]; then
        echo "live-patches: ordinal $target_ordinal is not the next configured batch" >&2
        return 1
      fi
      if [ "$pending_ordinal" != 0 ] && \
         { [ "$pending_ordinal" != "$target_ordinal" ] || [ "$pending_phase" != forward-transition ]; }; then
        echo "live-patches: ordinal $target_ordinal cannot be loaded while ordinal $pending_ordinal is $pending_phase" >&2
        return 1
      fi
      load_batch "$target_ordinal" || return 1
      scan_stack || return 1
      if [ "$active_tip" != "$target_ordinal" ] || [ "$pending_ordinal" != 0 ]; then
        echo "live-patches: ordinal $target_ordinal did not become the verified active tip" >&2
        return 1
      fi
    }

    unload_ordinal() {
      target_ordinal="$1"
      scan_stack || return 1
      if [ "$pending_ordinal" != 0 ]; then
        if [ "$pending_ordinal" != "$target_ordinal" ] || \
           { [ "$pending_phase" != reverse-transition ] && [ "$pending_phase" != disabled-present ] && \
             [ "$pending_phase" != cleanup-pending ]; }; then
          echo "live-patches: ordinal $target_ordinal cannot be unloaded while ordinal $pending_ordinal is $pending_phase" >&2
          return 1
        fi
      elif [ "$target_ordinal" = "$((active_tip + 1))" ]; then
        return 0
      elif [ "$target_ordinal" != "$active_tip" ]; then
        echo "live-patches: ordinal $target_ordinal is not the active tip" >&2
        return 1
      fi

      unload_batch "$target_ordinal" || return 1
      scan_stack || return 1
      if [ "$active_tip" != "$((target_ordinal - 1))" ] || [ "$pending_ordinal" != 0 ]; then
        echo "live-patches: ordinal $target_ordinal did not leave the expected prefix" >&2
        return 1
      fi
    }

    load_all() {
      while :; do
        scan_stack || return 1
        if [ "$active_tip" = "$configured_count" ] && [ "$pending_ordinal" = 0 ]; then
          return 0
        fi
        next=$((active_tip + 1))
        if [ "$pending_ordinal" != 0 ] && \
           { [ "$pending_ordinal" != "$next" ] || [ "$pending_phase" != forward-transition ]; }; then
          echo "live-patches: configured stack cannot continue from ordinal $pending_ordinal state $pending_phase" >&2
          return 1
        fi
        load_batch "$next" || return 1
      done
    }

    unload_all() {
      while :; do
        scan_stack || return 1
        if [ "$pending_ordinal" != 0 ]; then
          if [ "$pending_phase" != reverse-transition ] && [ "$pending_phase" != disabled-present ] && \
             [ "$pending_phase" != cleanup-pending ]; then
            echo "live-patches: configured stack cannot unload from ordinal $pending_ordinal state $pending_phase" >&2
            return 1
          fi
          unload_batch "$pending_ordinal" || return 1
        elif [ "$active_tip" -gt 0 ]; then
          unload_batch "$active_tip" || return 1
        else
          return 0
        fi
      done
    }

    case "$#:$1" in
      1:load)
        lock_manager
        load_all
        ;;
      2:load)
        valid_ordinal "$2" || { usage; exit 1; }
        lock_manager
        load_to_ordinal "$2"
        ;;
      1:unload)
        lock_manager
        unload_all
        ;;
      2:unload)
        valid_ordinal "$2" || { usage; exit 1; }
        lock_manager
        unload_ordinal "$2"
        ;;
      1:list|1:status)
        report_inventory
        ;;
      *)
        usage
        ;;
    esac
  '';

  live-patches-util = pkgs.writeScriptBin "live-patches" (
    genericLivePatchesContent
    + optionalString (!genericBuildEnable && !buildEnable) ''
      echo Live Patching not enabled in machine config or no patches available
      exit 0
    ''
    + optionalString (!genericBuildEnable && buildEnable) ''
      case "$1" in
      load)
        ${moduleLoadContent}
        ;;
      unload)
        ${moduleUnloadContent}
        ;;
      list)
        ${moduleListContent}
        ;;
      status)
        ${moduleStatusContent}
        ;;
      *)
        echo "usage: $0 load|unload|list|status"
        ;;
      esac
    ''
  );
  activationManager =
    if livepatchTest != null && livepatchTest ? manager then
      livepatchTest.manager
    else
      "${live-patches-util}/bin/live-patches";
  automaticLoad = phase: ''
    if ! ${escapeShellArg activationManager} load; then
      echo "live-patches: automatic ${phase} activation failed; inspect live-patches status" >&2
    fi
  '';
in
{
  options = {
    services.live-patches.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Add the live-patches utility and all configured livepatch modules to
        the system.
      '';
    };

    services.live-patches.loadOnBoot = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Attempt once to load all configured livepatch batches in order, after
        the booted system generation has been recorded. A failed attempt is
        logged and does not prevent the host from booting.
      '';
    };

    services.live-patches.loadOnSwitch = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Attempt once to load all configured livepatch batches in order when a
        running host activates this generation with switch-to-configuration
        test or switch. Disabling this option never unloads active modules.
      '';
    };
  };
  config = mkMerge [
    {
      environment.etc."livepatch-store-path".text =
        if buildEnable then
          toString patches
        else if genericBuildEnable then
          concatStringsSep "\n" (map toString genericModulePackages)
        else
          "";
      environment.systemPackages = [ live-patches-util ];
      runit.services.live-patches = {
        run = "sleep inf";
        finish = "";
        log.enable = true;
        log.sendTo = "127.0.0.1";
        runlevels = [ "default" ];
        onChange = "ignore";
      };
    }

    (mkIf (cfg.enable && cfg.loadOnBoot) {
      boot.postBootCommands = automaticLoad "boot";
    })

    (mkIf (cfg.enable && cfg.loadOnSwitch) {
      system.activationScripts.livePatches = stringAfter [ "etc" ] ''
        if test -e /run/booted-system; then
          ${automaticLoad "live-switch"}
        fi
      '';
    })

    (mkIf buildEnable {
      system.build.livePatches = patches;
      environment.etc."vpsadminos/livepatch-monitor.json".text = builtins.toJSON {
        kernelVersion = config.boot.kernelVersion;
        module = patchModuleName;
        inherit patchVersion;
        kernelNotes = toString kernelNotes;
        kernelImage = "${kernel}/bzImage";
        patches = map (patch: {
          inherit (patch) name;
          version = availablePatches.getPatchVersion patch;
        }) availablePatches.filteredPatches;
      };
    })

    (mkIf genericBuildEnable {
      system.build.livePatchManager = live-patches-util;
      system.build.livePatchModules = listToAttrs (
        map (deployment: {
          name = deployment.batch.release;
          value = deployment.module;
        }) genericDeployments
      );
      environment.etc."vpsadminos/livepatch-monitor.json".text = builtins.toJSON {
        schemaVersion = 2;
        kernelVersion = config.boot.kernelVersion;
        modules = map (deployment: {
          module = deployment.batch.moduleName;
          patchVersion = deployment.batch.unameLevel.releaseOrdinal;
          kernelNotes = toString genericKernelNotes;
          kernelImage = genericKernelImage;
          patches = map (fix: {
            name = fix.id;
            version = deployment.batch.payloadRevision;
          }) deployment.batch.fixes;
        }) genericDeployments;
      };
    })
  ];
}
