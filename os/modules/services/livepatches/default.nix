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

  # Boot ABI bytes are frozen separately from their producing recipe: a
  # clean kernel rebuild generates a different signing certificate/build ID.
  # The helper pins binary/toolchain inputs; it selects no new boot line.
  # This lock belongs only to .95. Other supported kernels must retain their
  # own development/configuration outputs and ordinary build toolchain.
  useFrozenBootInputs = config.boot.kernelVersion == "6.12.95";
  bootInputs = import ../../../packages/linux/boot-6.12.95.nix;
  bootToolchain = bootInputs.toolchain;
  kernel =
    config.boot.kernelPackage
    // optionalAttrs useFrozenBootInputs {
      dev = bootInputs.kernel.dev.outPath;
      configfile = {
        outPath = bootInputs.kernel.configfile.outPath;
      };
    };
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
  selectedCatalog =
    if length configuredCatalog <= 1 then
      configuredCatalog
    else
      throw "the scalar livepatch manager accepts at most one release for the configured kernel";
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
  genericDeployment =
    if normalizedGenericCatalog == [ ] then
      null
    else
      let
        catalogEntry = head normalizedGenericCatalog;
        batch = catalogEntry.batch;
        module = livepatchModule {
          inherit batch;
          kpatchBuild = genericKpatchBuild;
          targetBuild = configuredTarget.targetBuild;
        };
      in
      assert batch.unameLevel.releaseOrdinal == 1;
      assert batch.unameLevel.protocol == "vpsadminos-additive-uname-v1";
      assert batch.unameLevel.predecessorOrdinal == null;
      assert batch.unameLevel.rollbackRelease == batch.kernelTarget.kernelVersion;
      assert batch.mode == "additive";
      assert batch.lineage.depth == 0;
      assert batch.lineage.predecessorBatch == null;
      assert !batch.runtime.bootAutoload;
      assert module.batch == batch;
      assert module.manifest == batch.manifest;
      assert module.kernelTarget == configuredTarget.kernelTarget;
      assert module.targetIdentity == configuredTarget.targetBuild.identity;
      assert module.batch.kernelTarget == configuredTarget.kernelTarget;
      assert module.batch.kernelTarget.identity == configuredTarget.targetBuild.identity;
      {
        inherit batch catalogEntry module;
      };
  genericBatch = if genericDeployment == null then null else genericDeployment.batch;
  genericBuildEnable = genericDeployment != null && cfg.enable;

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

  genericModulePackage = if genericDeployment == null then null else genericDeployment.module;
  genericModuleFile =
    if genericDeployment == null then null else "${genericModulePackage}/${genericBatch.installPath}";
  genericEvidenceDir =
    if genericDeployment == null then null else "${genericModulePackage}/share/vpsadminos-livepatch";
  genericExpectedManifest =
    if genericDeployment == null then
      null
    else
      pkgs.writeText "${genericBatch.moduleName}-runtime-manifest.json" (
        builtins.toJSON genericBatch.manifest
      );
  genericRuntime =
    if livepatchTest != null then
      livepatchTest.runtime
    else
      {
        appliedDir = "/run/vpsadminos/livepatches";
        bootedKernel = "/run/booted-system/kernel";
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
        runningNotes = "/sys/kernel/notes";
        sysModuleRoot = "/sys/module";
        uname = "${pkgs.coreutils}/bin/uname";
      };
  genericKernelImage =
    if livepatchTest == null then "${kernel}/bzImage" else livepatchTest.kernelImage;
  genericKernelNotes = if livepatchTest == null then kernelNotes else livepatchTest.kernelNotes;

  buildLivePatch =
    {
      availablePatchesList,
      availablePatchTargets,
      stdenv,
    }:
    stdenv.mkDerivation rec {
      name = "${patchModuleName}-${kernel.modDirVersion}";
      version = toString patchVersion;
      src = patchesDir;

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
                if ! ${optionalString useFrozenBootInputs ''PATH="${bootToolchain}/bin:$PATH" ''}$kpb/kpatch-build/kpatch-build -v ${kernel.dev}/vmlinux -s src -n ${patchModuleName} ''
      + concatMapStrings (target: "-t ${escapeShellArg target} ") availablePatchTargets
      + concatMapStringsSep " " (name: "$src/${name}.patch") availablePatchesList
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

  genericPatchDir =
    if genericDeployment == null then
      null
    else
      "${genericRuntime.livepatchRoot}/${genericBatch.moduleName}";
  genericSysModuleDir =
    if genericDeployment == null then
      null
    else
      "${genericRuntime.sysModuleRoot}/${genericBatch.moduleName}";
  genericReleaseLink =
    if genericDeployment == null then
      null
    else
      "${genericRuntime.modulesRoot}/${genericBatch.unameLevel.publishedRelease}";
  genericObjects =
    if genericDeployment == null then
      [ ]
    else
      unique (map (function: function.object) genericBatch.build.expected.functions);
  genericObjectChecks = concatMapStringsSep "\n" (
    object:
    let
      objectDir = "${genericPatchDir}/${object}";
    in
    ''
      object_state=$(read_boolean ${escapeShellArg "${objectDir}/patched"}) || return 1
      if [ "$object_state" != 1 ]; then
        echo "live-patches: target object ${object} is not patched" >&2
        report_state
        return 1
      fi
    ''
  ) genericObjects;
  genericFunctionChecks = concatMapStringsSep "\n" (
    function:
    let
      sysfsSympos = if function.sympos == 0 then 1 else function.sympos;
      functionDir = "${genericPatchDir}/${function.object}/${function.symbol},${toString sysfsSympos}";
    in
    ''
      if [ ! -d ${escapeShellArg functionDir} ]; then
        echo "live-patches: target function ${function.object}:${function.symbol}:${toString function.sympos} is missing" >&2
        report_state
        return 1
      fi
    ''
  ) (if genericDeployment == null then [ ] else genericBatch.build.expected.functions);

  genericLivePatchesContent = optionalString genericBuildEnable ''
    patch_dir=${escapeShellArg genericPatchDir}
    sys_module_dir=${escapeShellArg genericSysModuleDir}
    applied_marker=${escapeShellArg "${genericRuntime.appliedDir}/${genericBatch.moduleName}.applied-at"}
    release_link=${escapeShellArg genericReleaseLink}
    booted_modules_tree=${escapeShellArg genericRuntime.bootedModulesTree}
    native_mod_dir=${escapeShellArg kernel.modDirVersion}
    store_root=${escapeShellArg genericRuntime.storeRoot}
    module_tree=

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
      echo "live-patches: release=${genericBatch.release} ordinal=${toString genericBatch.unameLevel.releaseOrdinal} payload-revision=${toString genericBatch.payloadRevision} expected-release=${genericBatch.unameLevel.publishedRelease} current-release=$current_release" >&2
      echo "live-patches: ${genericBatch.moduleName} state enabled=$enabled_state transition=$transition_state replace=$replace_state" >&2
      if [ -d ${escapeShellArg genericRuntime.livepatchRoot} ]; then
        for observed in ${escapeShellArg genericRuntime.livepatchRoot}/*; do
          [ -e "$observed" ] || continue
          observed_name=$(${pkgs.coreutils}/bin/basename "$observed")
          [ "$observed_name" = ${escapeShellArg genericBatch.moduleName} ] && continue
          observed_enabled=$(state_or_missing "$observed/enabled")
          observed_transition=$(state_or_missing "$observed/transition")
          observed_replace=$(state_or_missing "$observed/replace")
          echo "live-patches: unmanaged $observed_name state enabled=$observed_enabled transition=$observed_transition replace=$observed_replace" >&2
        done
      fi
    }

    read_boolean() {
      if [ ! -f "$1" ]; then
        echo "live-patches: missing state file $1" >&2
        return 1
      fi
      value=$(${pkgs.coreutils}/bin/cat "$1" 2>/dev/null) || {
        echo "live-patches: cannot read state file $1" >&2
        return 1
      }
      case "$value" in
        0|1) printf '%s' "$value" ;;
        *)
          echo "live-patches: invalid boolean state in $1: $value" >&2
          return 1
          ;;
      esac
    }

    check_boot_identity() {
      if [ "$(${pkgs.coreutils}/bin/readlink -f ${escapeShellArg genericRuntime.bootedKernel})" != ${escapeShellArg genericKernelImage} ] || \
         ! ${pkgs.diffutils}/bin/cmp -s ${escapeShellArg genericKernelNotes} ${escapeShellArg genericRuntime.runningNotes}; then
        echo "live-patches: configured module does not match the running boot kernel" >&2
        echo "live-patches: existing livepatches are unchanged; boot the configured kernel before managing this module" >&2
        return 1
      fi
    }

    check_release() {
      expected_release="$1"
      context="$2"
      current_release=$(${genericRuntime.uname} -r 2>/dev/null) || {
        echo "live-patches: cannot read uname release during $context" >&2
        return 1
      }
      if [ "$current_release" != "$expected_release" ]; then
        echo "live-patches: uname release $current_release does not match expected $expected_release during $context" >&2
        return 1
      fi
    }

    check_module_identity() {
      if [ ! -f ${escapeShellArg genericModuleFile} ] || \
         [ ! -f ${escapeShellArg "${genericEvidenceDir}/manifest.json"} ] || \
         [ ! -f ${escapeShellArg "${genericEvidenceDir}/inspection.json"} ] || \
         [ ! -f ${escapeShellArg "${genericEvidenceDir}/closure.json"} ]; then
        echo "live-patches: ${genericBatch.moduleName} module evidence is incomplete" >&2
        return 1
      fi
      if ! ${pkgs.diffutils}/bin/cmp -s ${escapeShellArg genericExpectedManifest} ${escapeShellArg "${genericEvidenceDir}/manifest.json"}; then
        echo "live-patches: ${genericBatch.moduleName} manifest identity mismatch" >&2
        return 1
      fi
      if ! ${pkgs.jq}/bin/jq -e '.matches == true' ${escapeShellArg "${genericEvidenceDir}/closure.json"} >/dev/null; then
        echo "live-patches: ${genericBatch.moduleName} closure evidence is not successful" >&2
        return 1
      fi
      if ! ${pkgs.jq}/bin/jq -e \
        '.buildInvocation == { flags: ["--non-replace"], nonReplaceRequested: true }' \
        ${escapeShellArg "${genericEvidenceDir}/inspection.json"} >/dev/null; then
        echo "live-patches: ${genericBatch.moduleName} was not built in additive mode" >&2
        return 1
      fi
      inspection_name=$(${pkgs.jq}/bin/jq -er '.module.name' ${escapeShellArg "${genericEvidenceDir}/inspection.json"}) || return 1
      expected_sha=$(${pkgs.jq}/bin/jq -er \
        '.module.sha256 | select(type == "string" and test("^[0-9a-f]{64}$"))' \
        ${escapeShellArg "${genericEvidenceDir}/inspection.json"}) || return 1
      actual_sha=$(${pkgs.coreutils}/bin/sha256sum ${escapeShellArg genericModuleFile} | \
        ${pkgs.coreutils}/bin/cut -d ' ' -f 1)
      if [ "$inspection_name" != ${escapeShellArg genericBatch.moduleName} ] || \
         [ "$actual_sha" != "$expected_sha" ]; then
        echo "live-patches: ${genericBatch.moduleName} module identity mismatch" >&2
        return 1
      fi
    }

    check_clean_set() {
      if [ ! -d ${escapeShellArg genericRuntime.livepatchRoot} ]; then
        return 0
      fi
      for existing in ${escapeShellArg genericRuntime.livepatchRoot}/*; do
        [ -e "$existing" ] || continue
        existing_name=$(${pkgs.coreutils}/bin/basename "$existing")
        if [ "$existing_name" != ${escapeShellArg genericBatch.moduleName} ]; then
          echo "live-patches: unsupported livepatch $existing_name is present" >&2
          report_state
          return 1
        fi
      done
    }

    resolve_module_tree() {
      booted_tree_resolved=$(${pkgs.coreutils}/bin/readlink -f "$booted_modules_tree" 2>/dev/null) || {
        echo "live-patches: cannot resolve booted module-tree authority $booted_modules_tree" >&2
        return 1
      }
      case "$booted_tree_resolved" in
        "$store_root"/*) ;;
        *)
          echo "live-patches: booted module-tree authority is not an immutable store path" >&2
          return 1
          ;;
      esac

      native_tree="$booted_tree_resolved/lib/modules/$native_mod_dir"
      if [ ! -d "$native_tree" ]; then
        echo "live-patches: native module tree $native_tree is missing" >&2
        return 1
      fi
      module_tree=$(${pkgs.coreutils}/bin/readlink -f "$native_tree" 2>/dev/null) || {
        echo "live-patches: cannot resolve native module tree $native_tree" >&2
        return 1
      }
      case "$module_tree" in
        "$store_root"/*) ;;
        *)
          echo "live-patches: native module tree does not resolve into the immutable store" >&2
          return 1
          ;;
      esac
    }

    verify_release_link() {
      resolve_module_tree || return 1
      if [ ! -L "$release_link" ]; then
        echo "live-patches: module-tree path $release_link is not the owned symlink" >&2
        return 1
      fi
      link_target=$(${pkgs.coreutils}/bin/readlink "$release_link" 2>/dev/null) || {
        echo "live-patches: cannot read module-tree symlink $release_link" >&2
        return 1
      }
      if [ "$link_target" != "$module_tree" ]; then
        echo "live-patches: module-tree symlink $release_link is not owned by this batch" >&2
        return 1
      fi
      resolved_link=$(${pkgs.coreutils}/bin/readlink -f "$release_link" 2>/dev/null) || {
        echo "live-patches: cannot resolve module-tree symlink $release_link" >&2
        return 1
      }
      if [ "$resolved_link" != "$module_tree" ]; then
        echo "live-patches: resolved module-tree symlink $release_link is not owned by this batch" >&2
        return 1
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
      ${genericObjectChecks}
      ${genericFunctionChecks}
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
        echo "live-patches: cannot record ${genericBatch.moduleName} application time" >&2
        return 1
      fi
      ${pkgs.coreutils}/bin/mv "$marker_tmp" "$applied_marker"
    }

    load_batch() {
      ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname ${escapeShellArg genericRuntime.lockFile})"
      exec 9>${escapeShellArg genericRuntime.lockFile}
      ${pkgs.util-linux}/bin/flock -x 9

      check_boot_identity || return 1
      check_module_identity || return 1
      check_clean_set || return 1

      if [ ! -d "$patch_dir" ]; then
        check_release ${escapeShellArg genericBatch.unameLevel.rollbackRelease} "load preflight" || return 1
        if [ -e "$applied_marker" ]; then
          echo "live-patches: stale applied marker exists for unloaded ${genericBatch.moduleName}" >&2
          return 1
        fi
        ensure_release_link || return 1
        echo "live-patches: loading and applying ${genericBatch.moduleName}..."
        if ! ${genericRuntime.insmod} ${escapeShellArg genericModuleFile}; then
          echo "live-patches: loading and applying ${genericBatch.moduleName} FAILED" >&2
          report_state
          return 1
        fi
      else
        ensure_release_link || return 1
      fi

      attempt=0
      while [ "$attempt" -lt ${toString genericRuntime.pollAttempts} ]; do
        read_runtime_state || {
          report_state
          return 1
        }
        if [ "$replace_state" != 0 ]; then
          echo "live-patches: ${genericBatch.moduleName} unexpectedly has replace=1" >&2
          report_state
          return 1
        fi
        if [ "$enabled_state" = 1 ] && [ "$transition_state" = 0 ]; then
          verify_coverage || return 1
          check_boot_identity || return 1
          check_release ${escapeShellArg genericBatch.unameLevel.publishedRelease} "load convergence" || {
            report_state
            return 1
          }
          verify_release_link || return 1
          publish_applied || return 1
          return 0
        fi
        if [ "$enabled_state" != 1 ] || [ "$transition_state" != 1 ]; then
          echo "live-patches: ${genericBatch.moduleName} entered an unexpected state" >&2
          report_state
          return 1
        fi

        attempt=$((attempt + 1))
        if [ "$attempt" -lt ${toString genericRuntime.pollAttempts} ]; then
          ${pkgs.coreutils}/bin/sleep ${escapeShellArg (toString genericRuntime.pollInterval)}
        fi
      done

      echo "live-patches: ${genericBatch.moduleName} did not converge within the activation deadline" >&2
      report_state
      return 1
    }

    finish_unload_cleanup() {
      check_boot_identity || return 1
      check_release ${escapeShellArg genericBatch.unameLevel.rollbackRelease} "unload cleanup" || return 1
      if [ ! -f "$applied_marker" ]; then
        echo "live-patches: ${genericBatch.moduleName} has no owned applied marker" >&2
        return 1
      fi

      if [ -d "$sys_module_dir" ]; then
        verify_release_link || return 1
        if ! ${genericRuntime.rmmod} ${escapeShellArg genericBatch.moduleName}; then
          echo "live-patches: removing ${genericBatch.moduleName} FAILED" >&2
          return 1
        fi
        if [ -d "$sys_module_dir" ]; then
          echo "live-patches: ${genericBatch.moduleName} remains loaded after removal" >&2
          return 1
        fi
      fi

      if [ -e "$release_link" ] || [ -L "$release_link" ]; then
        remove_release_link || return 1
      fi
      if ! ${pkgs.coreutils}/bin/rm -- "$applied_marker"; then
        echo "live-patches: cannot remove ${genericBatch.moduleName} applied marker" >&2
        return 1
      fi
    }

    unload_batch() {
      ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname ${escapeShellArg genericRuntime.lockFile})"
      exec 9>${escapeShellArg genericRuntime.lockFile}
      ${pkgs.util-linux}/bin/flock -x 9

      check_boot_identity || return 1
      check_module_identity || return 1
      check_clean_set || return 1

      if [ ! -d "$patch_dir" ]; then
        if [ ! -d "$sys_module_dir" ] && [ ! -e "$applied_marker" ] && \
           [ ! -L "$applied_marker" ] && [ ! -e "$release_link" ] && \
           [ ! -L "$release_link" ]; then
          check_release ${escapeShellArg genericBatch.unameLevel.rollbackRelease} "unload no-op" || return 1
          return 0
        fi

        if [ ! -f "$applied_marker" ]; then
          echo "live-patches: ${genericBatch.moduleName} has inconsistent residual state" >&2
          report_state
          return 1
        fi
        if [ -d "$sys_module_dir" ] && [ ! -e "$release_link" ] && [ ! -L "$release_link" ]; then
          echo "live-patches: loaded residual ${genericBatch.moduleName} has no owned module-tree link" >&2
          return 1
        fi
        if [ -e "$release_link" ] || [ -L "$release_link" ]; then
          verify_release_link || return 1
        fi
        finish_unload_cleanup
        return
      fi

      if [ ! -f "$applied_marker" ]; then
        echo "live-patches: ${genericBatch.moduleName} has no owned applied marker" >&2
        return 1
      fi
      verify_release_link || return 1
      if [ ! -d "$sys_module_dir" ]; then
        echo "live-patches: loaded module ${genericBatch.moduleName} is missing from sysfs" >&2
        return 1
      fi

      read_runtime_state || {
        report_state
        return 1
      }
      if [ "$replace_state" != 0 ]; then
        echo "live-patches: ${genericBatch.moduleName} unexpectedly has replace=1" >&2
        report_state
        return 1
      fi

      if [ "$enabled_state" = 1 ] && [ "$transition_state" = 0 ]; then
        verify_coverage || return 1
        check_release ${escapeShellArg genericBatch.unameLevel.publishedRelease} "unload preflight" || return 1
        check_boot_identity || return 1
        if ! ${genericRuntime.disable} "$patch_dir/enabled"; then
          echo "live-patches: disabling ${genericBatch.moduleName} FAILED" >&2
          report_state
          return 1
        fi
      elif [ "$enabled_state" = 0 ] && [ "$transition_state" = 1 ]; then
        : # Resume observation without repeating the disable write.
      elif [ "$enabled_state" = 0 ] && [ "$transition_state" = 0 ]; then
        check_release ${escapeShellArg genericBatch.unameLevel.rollbackRelease} "unload convergence" || return 1
      else
        echo "live-patches: ${genericBatch.moduleName} is not safe to unload" >&2
        report_state
        return 1
      fi

      attempt=0
      while [ "$attempt" -lt ${toString genericRuntime.pollAttempts} ]; do
        if [ ! -d "$patch_dir" ]; then
          check_boot_identity || return 1
          check_release ${escapeShellArg genericBatch.unameLevel.rollbackRelease} "unload convergence" || return 1
          break
        fi

        read_runtime_state || {
          report_state
          return 1
        }
        if [ "$replace_state" != 0 ]; then
          echo "live-patches: ${genericBatch.moduleName} unexpectedly has replace=1" >&2
          report_state
          return 1
        fi
        if [ "$enabled_state" != 0 ] || \
           { [ "$transition_state" != 0 ] && [ "$transition_state" != 1 ]; }; then
          echo "live-patches: ${genericBatch.moduleName} entered an unexpected reverse state" >&2
          report_state
          return 1
        fi
        if [ "$transition_state" = 0 ]; then
          check_release ${escapeShellArg genericBatch.unameLevel.rollbackRelease} "unload convergence" || {
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
        echo "live-patches: ${genericBatch.moduleName} did not finish reverse transition within the deadline" >&2
        report_state
        return 1
      fi
      finish_unload_cleanup
    }

    case "$1" in
    load)
      load_batch
      ;;
    list|status)
      report_state
      ;;
    unload)
      unload_batch
      ;;
    *)
      echo "usage: $0 load|unload|list|status"
      exit 1
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
      if [ "$(readlink -f /run/booted-system/kernel)" != "${kernel}/bzImage" ] || \
         ! ${pkgs.diffutils}/bin/cmp -s ${kernelNotes} /sys/kernel/notes; then
        echo "live-patches: configured module does not match the running boot kernel" >&2
        echo "live-patches: existing livepatches are unchanged; boot the configured kernel before managing this module" >&2
        exit 1
      fi

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
in
{
  options = {
    services.live-patches.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Add the live-patches utility and compiled livepatch modules to the system.
        Legacy opt-in livepatches are loaded automatically by the boot service.
        Numbered releases follow runtime.bootAutoload; current numbered releases
        set it to false and require explicit activation with live-patches load.
        Deploying either type to an already running machine does not trigger the
        boot service, so activation there is also manual.
      '';
    };
  };
  config = mkMerge [
    {
      environment.etc."livepatch-store-path".text =
        if buildEnable then
          toString patches
        else if genericBuildEnable then
          toString genericModulePackage
        else
          "";
      environment.systemPackages = [ live-patches-util ];
      runit.services.live-patches = {
        run =
          (optionalString (
            buildEnable || (genericBuildEnable && genericBatch.runtime.bootAutoload)
          ) "live-patches load && ")
          + "sleep inf";
        finish = optionalString (buildEnable) "live-patches unload";
        log.enable = true;
        log.sendTo = "127.0.0.1";
        runlevels = [ "default" ];
        onChange = "ignore";
      };
    }

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
      system.build.livePatchModules.${genericBatch.release} = genericModulePackage;
      environment.etc."vpsadminos/livepatch-monitor.json".text = builtins.toJSON {
        kernelVersion = config.boot.kernelVersion;
        module = genericBatch.moduleName;
        patchVersion = genericBatch.unameLevel.releaseOrdinal;
        kernelNotes = toString genericKernelNotes;
        kernelImage = genericKernelImage;
        patches = map (fix: {
          name = fix.id;
          version = genericBatch.payloadRevision;
        }) genericBatch.fixes;
      };
    })
  ];
}
