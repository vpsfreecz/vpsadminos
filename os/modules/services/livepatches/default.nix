{ config, lib, pkgs, utils, ... }:
with lib;

let
  cfg = config.services.live-patches;

  livepatchesDir = ../../../livepatches;
  kpatchBuildPatchesDir = livepatchesDir + "/kpatch-build";
  manualPatchesDir = livepatchesDir + "/manual";
  availablePatchesKpatchBuild = import (kpatchBuildPatchesDir + /availablePatches.nix);
  availablePatchesManual = import (manualPatchesDir + /availablePatches.nix);

  numPatchesManual = length availablePatchesManual;
  numPatchesKpatchBuild = length availablePatchesKpatchBuild;

  kernel = config.boot.kernelPackage;
  kpatch-build = pkgs.callPackage (import ../../../packages/kpatch-build/default.nix) {};

  moduleLoadGen = { moduleName, installModPath }:
    ''
      if [ ! -d /sys/kernel/livepatch/${moduleName} ]; then
        echo live-patches: loading and applying ${moduleName}...
        if ! insmod ${installModPath}; then
          echo live-patches: loading and applying ${moduleName} FAILED
        fi
      fi
    '';

  moduleUnloadGen = { moduleName }:
    ''
      if [ -d /sys/kernel/livepatch/${moduleName} ] && [ -f /sys/kernel/livepatch/${moduleName}/enabled ]; then
        echo -en live-patches: disabling ${moduleName}.. 
        echo 0 > /sys/kernel/livepatch/${moduleName}/enabled 2>/dev/null
        retries=91
        while [ -d /sys/kernel/livepatch/${moduleName} ] && [ $retries -gt 0 ]; do
          if [ "$(( $retries % 5 ))" -eq 0 ]; then
            echo -en " $retries "
          fi
          transition=$(cat /sys/kernel/livepatch/${moduleName}/transition 2>/dev/null)
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

  moduleStatusGen = { moduleName, extraText ? "" }:
    ''
      s="["
      if [ -d /sys/module/${moduleName} ]; then
        s="$s loaded";
        if [ -f /sys/kernel/livepatch/${moduleName}/enabled ] && \
           [ "$(cat /sys/kernel/livepatch/${moduleName}/enabled 2>/dev/null)" == "1" ]; then
          s="$s enabled"
        fi
        if [ "$(cat /sys/kernel/livepatch/${moduleName}/transition 2>/dev/null)" == "1" ]; then
          s="$s transition"
        fi
      else
        s="$s unloaded"
      fi
      printf "%-27s%s\n" "$s" " ] ${moduleName}${extraText}"
    '';

  buildLivePatchKpatch = { availablePatchesKpatchBuild, ccacheStdenv }:
    let
      patchName = "${toString numPatchesKpatchBuild}-${builtins.replaceStrings ["."] ["-"] (last availablePatchesKpatchBuild)}";
      patchModuleName = "klp_${builtins.replaceStrings ["-"] ["_"] patchName}";
    in ccacheStdenv.mkDerivation rec {
      name = "livepatch-${kernel.modDirVersion}-kpatch-build";
      version = toString numPatchesKpatchBuild;
      src = kpatchBuildPatchesDir;

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
      concatMapStringsSep " " (name: "${name}.patch") availablePatchesKpatchBuild +
      ''; # we dont get a newline between this and the next line; wtf
        # actual command
        $kpb/kpatch-build/kpatch-build -s src -n ${patchModuleName} '' +
      concatMapStringsSep " " (name: "$src/${name}.patch") availablePatchesKpatchBuild +
      '' || ((tail -n 150 $CACHEDIR/build.log || echo log not found at $CACHEDIR/build.log) && exit 1)
      '';

      nativeBuildInputs = with pkgs; [ perl bc nettools openssl rsync gmp
                          libmpc mpfr gawk zstd elfutils cpio bison flex ];

      installModDir = "lib/modules/${kernel.modDirVersion}/extra";
      installModPath = "${installModDir}/${patchModuleName}.ko";
      installPhase = ''
        mkdir -p $out/${installModDir};
        cp ${patchModuleName}.ko $out/${installModPath} || (ls -lah && exit 1)

        cat > $out/moduleLoadContent <<moduleLoadContent
          mkdir -p /lib/modules
          ln -snf /run/current-system/kernel-modules/lib/modules/${kernel.modDirVersion} /lib/modules/${kernel.modDirVersion}.${patchName}
          '' + moduleLoadGen { installModPath = "$out/${installModPath}";
                               moduleName = patchModuleName; } + ''
moduleLoadContent

        cat > $out/moduleUnloadContent <<"moduleUnloadContent"
          '' + moduleUnloadGen { moduleName = patchModuleName; } + ''
moduleUnloadContent

        cat > $out/moduleStatusContent <<"moduleStatusContent"
          '' + moduleStatusGen {
                 moduleName = patchModuleName;
                 extraText = "(" + concatStringsSep " " availablePatchesKpatchBuild + ")";
               } + ''
moduleStatusContent
      '';
    };

  kpatchBuildPatches = pkgs.callPackage buildLivePatchKpatch { inherit availablePatchesKpatchBuild; };

  buildLivePatchManual = { patchName, stdenv }:
    stdenv.mkDerivation rec {
      name = "klp-${kernel.modDirVersion}-${patchName}";
      version = toString numPatchesManual;
      src = manualPatchesDir;

      configurePhase = ''
        mkdir ${patchName}
        cp $src/${patchName}.c ${patchName}/klp-${patchName}.c
        echo 'obj-m += klp-${patchName}.o' > ${patchName}/Makefile
      '';
      buildPhase = ''
        cd ${patchName}
        make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build \
          -j$NIX_BUILD_CORES M=$(pwd) modules
      '';
      installPhase = ''
        make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build  \
          INSTALL_MOD_PATH=$out M=$(pwd) modules_install
      '';
    };

  insmodLineGen = patchName:
    let
      dirName = "klp_" + builtins.replaceStrings ["-"] ["_"] patchName;

      patch = pkgs.callPackage buildLivePatchManual { inherit patchName; };

      ko = "${patch}/lib/modules/${kernel.modDirVersion}/extra/klp-${patchName}.ko";
    in
      moduleLoadGen { installModPath = "${ko}*"; moduleName = dirName; };

  manualModuleLoadContent = concatMapStringsSep "\n" insmodLineGen availablePatchesManual;

  moduleLoadContent = ''
    # Patches built with build-kpatch
    . $(cat /etc/kpatchBuildPatches)/moduleLoadContent
    # Patches built using .c modules
    ${manualModuleLoadContent}
  '';

  manualModulesListString = concatMapStringsSep " " (name: "klp-${name}") availablePatchesManual;
  moduleUnloadContent = ''
    # Patches built with build-kpatch
    . $(cat /etc/kpatchBuildPatches)/moduleUnloadContent
    # Patches built using .c modules
    modules="${manualModulesListString}"
    for patchModuleName in $modules; do
      '' + moduleUnloadGen { moduleName = "\$patchModuleName"; } + ''
    done
  '';

  moduleStatusContent = ''
    . $(cat /etc/kpatchBuildPatches)/moduleStatusContent
    modules="${manualModulesListString}"
    for patchModuleName in $modules; do
      '' + moduleStatusGen { moduleName = "\$patchModuleName"; } + ''
    done
  '';

  live-patches-util = pkgs.writeScriptBin "live-patches" ''
    case "$1" in
    load)
      ${moduleLoadContent}
      ;;
    unload)
      ${moduleUnloadContent}
      ;;
    status|list)
      ${moduleStatusContent}
      ;;
    *)
      echo "usage: $0 load|unload|status"
      ;;
    esac
  '';

in
{
  options = {
    services.live-patches.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Enable/disable Live Patching
      '';
    };
  };
  config = {
    environment.etc."kpatchBuildPatches".text = toString kpatchBuildPatches;
    environment.systemPackages = [ live-patches-util ];
    runit.services.live-patches = {
      run = optionalString (cfg.enable) "live-patches load && sleep inf";
      finish = optionalString (cfg.enable) "live-patches unload";
      runlevels = [ "default" ];
    };
  };
}

