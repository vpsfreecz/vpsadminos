{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
with lib;

let
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

  # Boot ABI and compiler inputs retain their producing derivations, so a
  # fresh builder can obtain the exact reviewed outputs without local paths.
  # The helper asserts their identities; it does not select a new boot line.
  bootInputs = import ../../../packages/linux/boot-6.12.95.nix;
  bootToolchain = bootInputs.toolchain;
  kernel = config.boot.kernelPackage // {
    dev = bootInputs.kernel.dev.outPath;
    configfile = {
      outPath = bootInputs.kernel.configfile.outPath;
    };
  };
  kpatch-build = pkgs.callPackage (import ../../../packages/kpatch-build/default.nix) { };

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
                if ! PATH="${bootToolchain}/bin:$PATH" $kpb/kpatch-build/kpatch-build -v ${kernel.dev}/vmlinux -s src -n ${patchModuleName} ''
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

  live-patches-util = pkgs.writeScriptBin "live-patches" (
    optionalString (!buildEnable) ''
      echo Live Patching not enabled in machine config or no patches available
      exit 0
    ''
    + optionalString (buildEnable) ''
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
        When enabled, live-patches utility is added to system path along with compiled live patch kernel modules.
        Note, patches are automatically loaded only upon machine boot, live-patches
        util has to be called manually to load them when deploying onto a running machine.
      '';
    };
  };
  config = mkMerge [
    {
      environment.etc."livepatch-store-path".text =
        "" + (optionalString (buildEnable) (toString patches));
      environment.systemPackages = [ live-patches-util ];
      runit.services.live-patches = {
        run = (optionalString (buildEnable) "live-patches load && ") + "sleep inf";
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
  ];
}
