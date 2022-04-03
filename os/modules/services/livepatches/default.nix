{ config, lib, pkgs, utils, ... }:
with lib;

let
  cfg = config.services.live-patches;

  patchesDir = ../../../livepatches;
  availablePatches = import (patchesDir + /availablePatches.nix) { inherit lib; version = config.boot.kernelVersion; };
  availablePatchesList = availablePatches.patchList;
  patchVersion = availablePatches.patchVersion;

  buildEnable = (patchVersion > 0) && cfg.enable;

  kernel = config.boot.kernelPackage;
  kpatch-build = pkgs.callPackage (import ../../../packages/kpatch-build/default.nix) {};

  patchName = "${toString patchVersion}-livepatched";
  patchModuleName = "livepatch_${toString patchVersion}";
  installModDir = "lib/modules/${kernel.modDirVersion}/extra";
  installModPath = "${installModDir}/${patchModuleName}.ko";

  buildLivePatch = { availablePatchesList, ccacheStdenv }:
    ccacheStdenv.mkDerivation rec {
      name = "${patchModuleName}-${kernel.modDirVersion}";
      version = toString patchVersion;
      src = patchesDir;

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

        echo patchShebangs src/scripts
        patchShebangs src/scripts > /dev/null

        # kpatch-build needs the whole env to be writeable, even the stuff
        # we just unpacked and copied
        chmod u+w . -R

        cat > src/include/linux/vpsadminos-livepatch.h <<LIVEPATCH_HEADER_END
#ifndef VPSADMINOS_LIVEPATCH_H
#define VPSADMINOS_LIVEPATCH_H
#define LIVEPATCH_ORIG_KERNEL_VERSION        "${kernel.modDirVersion}"
#define LIVEPATCH_NAME                       "${patchName}"
#endif
LIVEPATCH_HEADER_END

        # command preview:
        echo kpatch-build -n ${patchModuleName} '' +
      concatMapStringsSep " " (name: "${name}.patch") availablePatchesList +
      ''; # we dont get a newline between this and the next line; wtf
        # actual command
        $kpb/kpatch-build/kpatch-build -s src -n ${patchModuleName} '' +
      concatMapStringsSep " " (name: "$src/${name}.patch") availablePatchesList +
      '' || ((tail -n 150 $CACHEDIR/build.log || echo log not found at $CACHEDIR/build.log) && exit 1)
      '';

      nativeBuildInputs = with pkgs; [ perl bc nettools openssl rsync gmp
                          libmpc mpfr gawk zstd elfutils cpio bison flex ];

      installPhase = ''
        mkdir -p $out/${installModDir};
        cp ${patchModuleName}.ko $out/${installModPath} || (ls -lah && exit 1)
      '';
    };

  patches = pkgs.callPackage buildLivePatch { inherit availablePatchesList; };

  moduleLoadGen = { moduleName, installModPath }:
    let
      modDetectDir = "/sys/kernel/livepatch/${moduleName}";
    in ''
      if [ ! -d ${modDetectDir} ]; then
        echo live-patches: loading and applying ${moduleName}...
        if ! insmod ${installModPath}; then
          echo live-patches: loading and applying ${moduleName} FAILED
        fi
      fi
    '';

  moduleUnloadGen = { moduleName }:
    let
      modDetectDir = "/sys/kernel/livepatch/${moduleName}";
    in ''
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
    '';

  moduleListGen = { moduleName }:
  let
    modDetectDir = "/sys/kernel/livepatch/${moduleName}";
  in ''
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

  moduleStatusGen = { moduleName }:
    moduleListGen { inherit moduleName; } +
    foldl (x: y: "${x}\n${y}") "\n" (map (patch:
          let
            pVer = availablePatches.getPatchVersion patch;
          in
            "printf '%29s %s\n' 'contains:' '${patch.name}" +
            optionalString (pVer > 1) "(v${toString pVer})" +
                                          "'") availablePatches.filteredPatches);

  moduleLoadContent = ''
    livepatch=$(cat /etc/livepatch-store-path)
    mkdir -p /lib/modules
    ln -snf /run/current-system/kernel-modules/lib/modules/${kernel.modDirVersion} /lib/modules/${kernel.modDirVersion}.${patchName}
  '' + moduleLoadGen { installModPath = "$livepatch/${installModPath}";
                         moduleName = patchModuleName; } + ''
  '';

  moduleUnloadContent = ''
    livepatch=$(cat /etc/livepatch-store-path)
    # Patches built with build-kpatch
  '' + moduleUnloadGen { moduleName = patchModuleName; } + "\n";

  moduleListContent = ''
    livepatch=$(cat /etc/livepatch-store-path)
  '' + moduleListGen { moduleName = patchModuleName; } + "\n";

  moduleStatusContent = ''
    livepatch=$(cat /etc/livepatch-store-path)
  '' + moduleStatusGen { moduleName = patchModuleName; } + "\n";

  live-patches-util = pkgs.writeScriptBin "live-patches" (optionalString(!buildEnable) ''
    echo Live Patching not enabled in machine config or no patches available
    exit 0
  '' + optionalString (buildEnable) ''
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
  '');
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
  config = {
    environment.etc."livepatch-store-path".text = "" + (optionalString (buildEnable) (toString patches));
    environment.systemPackages = [ live-patches-util ];
    runit.services.live-patches = {
      run = optionalString (buildEnable) "live-patches load && sleep inf";
      finish = optionalString (buildEnable) "live-patches unload";
      runlevels = [ "default" ];
    };
  };
}

