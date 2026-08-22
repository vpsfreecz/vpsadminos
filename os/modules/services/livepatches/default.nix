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
  zfsBuiltinPkg = config.boot.zfsBuiltinPkg;
  patchesDir = ../../../livepatches;
  availablePatches = import (patchesDir + /available-patches.nix) {
    inherit lib;
    version = config.boot.kernelVersion;
  };
  availablePatchesList = availablePatches.patchList;
  availablePatchTargets = availablePatches.patchTargets;
  transitionGuards = availablePatches.transitionGuards;
  transitionGuard =
    assert length transitionGuards <= 1;
    if transitionGuards == [ ] then null else head transitionGuards;
  patchVersion = availablePatches.patchVersion;

  buildEnable = (patchVersion > 0) && cfg.enable;

  kernel = config.boot.kernelPackage;
  kpatch-build = pkgs.callPackage (import ../../../packages/kpatch-build/default.nix) { };

  patchName = "${toString patchVersion}";
  patchModuleName = "livepatch_${toString patchVersion}";
  installModDir = "lib/modules/${kernel.modDirVersion}/extra";
  installModPath = "${installModDir}/${patchModuleName}.ko";
  guardModuleName = if transitionGuard == null then null else transitionGuard.moduleName;
  guardInstallModPath =
    if transitionGuard == null then null else "${installModDir}/${guardModuleName}.ko";

  buildKpatchCommand =
    {
      moduleName,
      buildPatches,
      targets,
      nonReplace ? false,
    }:
    let
      command =
        "$kpb/kpatch-build/kpatch-build -v ${kernel.dev}/vmlinux -s src "
        + "-n ${escapeShellArg moduleName} "
        + optionalString nonReplace "-R "
        + concatMapStrings (target: "-t ${escapeShellArg target} ") targets
        + concatMapStringsSep " " (name: "$src/${name}.patch") buildPatches;
    in
    ''
      echo ${command}
      if ! ${command}; then
        cat $CACHEDIR/build.log || echo log not found at $CACHEDIR/build.log
        exit 1
      fi
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
        # set to 3 if you want to see compile process
        export DEBUG=0

        # prepare kpatch-build and its environment
        export CCACHE_UMASK=007
        export CCACHE_DIR=/nix/var/cache/ccache
        export CACHEDIR=$(pwd)/tmp/cache
        export TEMPDIR=$(pwd)/tmp
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
        cp -r ${kernel.dev}/. ./src/
        ln -snf ${kernel.configfile.outPath} ./src/.config

        # A vmlinux-only guard build does not prepare module link inputs, so
        # seed the exact production-generated files used while linking the
        # generated livepatch module.
        cp ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build/Module.symvers \
          ./src/Module.symvers
        cp ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build/scripts/module.lds \
          ./src/scripts/module.lds

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

      ''
      + optionalString (transitionGuard != null) (buildKpatchCommand transitionGuard)
      + buildKpatchCommand {
        moduleName = patchModuleName;
        buildPatches = availablePatchesList;
        targets = availablePatchTargets;
      };

      nativeBuildInputs = kernel.nativeBuildInputs;

      installPhase = ''
        mkdir -p $out/${installModDir};
        cp ${patchModuleName}.ko $out/${installModPath} || (ls -lah && exit 1)
      ''
      + optionalString (transitionGuard != null) ''
        cp ${guardModuleName}.ko $out/${guardInstallModPath} || (ls -lah && exit 1)
      '';
    };

  patches = pkgs.callPackage buildLivePatch {
    inherit availablePatchesList availablePatchTargets;
  };

  moduleLoadGen =
    {
      moduleName,
      installModPath,
      recordApplied ? true,
    }:
    let
      modDetectDir = "/sys/kernel/livepatch/${moduleName}";
    in
    ''
      if [ ! -d ${modDetectDir} ]; then
        echo live-patches: loading and applying ${moduleName}...
        if ! insmod ${installModPath}; then
          echo live-patches: loading and applying ${moduleName} FAILED
        fi
      fi
    ''
    + optionalString recordApplied ''
      if [ -f ${modDetectDir}/enabled ] && [ "$(cat ${modDetectDir}/enabled 2>/dev/null)" = "1" ]; then
        mkdir -p /run/vpsadminos/livepatches
        if [ ! -e /run/vpsadminos/livepatches/${moduleName}.applied-at ]; then
          date --utc +%Y-%m-%dT%H:%M:%SZ \
            > /run/vpsadminos/livepatches/${moduleName}.applied-at
        fi
      fi
    '';

  moduleWaitGen =
    {
      moduleName,
      timeoutSeconds ? 900,
    }:
    let
      modDetectDir = "/sys/kernel/livepatch/${moduleName}";
    in
    ''
      retries=${toString (timeoutSeconds + 1)}
      while [ -d ${modDetectDir} ] && \
        [ "$(cat ${modDetectDir}/transition 2>/dev/null)" = "1" ] && \
        [ "$retries" -gt 0 ]; do
        if [ "$((retries % 30))" -eq 0 ]; then
          echo live-patches: waiting for ${moduleName} transition, "$retries" seconds remain
        fi
        retries=$((retries - 1))
        sleep 1
      done

      if [ ! -d ${modDetectDir} ] || \
        [ "$(cat ${modDetectDir}/enabled 2>/dev/null)" != "1" ] || \
        [ "$(cat ${modDetectDir}/transition 2>/dev/null)" != "0" ]; then
        echo live-patches: ${moduleName} transition FAILED
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
        echo 0 > ${modDetectDir}/enabled 2>/dev/null
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
          if [ "$retries" -eq 0 ]; then
            echo -en "\nlive-patches: unloading ${moduleName}... FAILED"
          fi
        done
        echo
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
  + optionalString (transitionGuard != null) ''
    if [ ! -d /sys/kernel/livepatch/${patchModuleName} ]; then
      ${moduleLoadGen {
        installModPath = "$livepatch/${guardInstallModPath}";
        moduleName = guardModuleName;
        recordApplied = false;
      }}
      if [ "$(cat /sys/kernel/livepatch/${guardModuleName}/enabled 2>/dev/null)" != "1" ]; then
        echo 1 > /sys/kernel/livepatch/${guardModuleName}/enabled 2>/dev/null || {
          echo live-patches: enabling ${guardModuleName} FAILED
          exit 1
        }
      fi
      ${moduleWaitGen { moduleName = guardModuleName; }}
    fi
  ''
  + moduleLoadGen {
    installModPath = "$livepatch/${installModPath}";
    moduleName = patchModuleName;
    recordApplied = transitionGuard == null;
  }
  + optionalString (transitionGuard != null) ''
    ${moduleWaitGen { moduleName = patchModuleName; }}
    mkdir -p /run/vpsadminos/livepatches
    if [ ! -e /run/vpsadminos/livepatches/${patchModuleName}.applied-at ]; then
      date --utc +%Y-%m-%dT%H:%M:%SZ \
        > /run/vpsadminos/livepatches/${patchModuleName}.applied-at
    fi
    retries=151
    while [ -d /sys/module/${guardModuleName} ] && [ "$retries" -gt 0 ]; do
      rmmod ${guardModuleName} 2>/dev/null || true
      retries=$((retries - 1))
      if [ -d /sys/module/${guardModuleName} ]; then
        sleep 0.2
      fi
    done
    if [ -d /sys/module/${guardModuleName} ]; then
      echo live-patches: unloading absorbed ${guardModuleName} FAILED
      exit 1
    fi
    rm -f /run/vpsadminos/livepatches/${guardModuleName}.applied-at
  ''
  + "";

  moduleUnloadContent = ''
    livepatch=$(cat /etc/livepatch-store-path)
    # Patches built with build-kpatch
  ''
  + moduleUnloadGen { moduleName = patchModuleName; }
  + optionalString (transitionGuard != null) (moduleUnloadGen {
    moduleName = guardModuleName;
  })
  + "\n";

  moduleListContent = ''
    livepatch=$(cat /etc/livepatch-store-path)
  ''
  + optionalString (transitionGuard != null) (moduleListGen {
    moduleName = guardModuleName;
  })
  + moduleListGen { moduleName = patchModuleName; }
  + "\n";

  moduleStatusContent = ''
    livepatch=$(cat /etc/livepatch-store-path)
  ''
  + optionalString (transitionGuard != null) (moduleListGen {
    moduleName = guardModuleName;
  })
  + moduleStatusGen { moduleName = patchModuleName; }
  + "\n";

  live-patches-util = pkgs.writeScriptBin "live-patches" (
    optionalString (!buildEnable) ''
      echo Live Patching not enabled in machine config or no patches available
      exit 0
    ''
    + optionalString (buildEnable) ''
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
        transitionGuard = guardModuleName;
        patches = map (patch: {
          inherit (patch) name;
          version = availablePatches.getPatchVersion patch;
        }) availablePatches.filteredPatches;
      };
    })
  ];
}
