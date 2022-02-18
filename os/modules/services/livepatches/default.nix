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

  kernel = pkgs.callPackage (import ../../../packages/linux/default.nix) {};
  kpatch-build = pkgs.callPackage (import ../../../packages/kpatch-build/default.nix) {};

  buildLivePatchKpatch = { availablePatchesKpatchBuild, ccacheStdenv }:
    ccacheStdenv.mkDerivation rec {
      name = "livepatch-${kernel.modDirVersion}-kpatch-build";
      version = toString numPatchesKpatchBuild;
      src = kpatchBuildPatchesDir;

      patchName = "klp-${version}-${builtins.replaceStrings ["."] ["-"] (last availablePatchesKpatchBuild)}";
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
        patchShebangs src/scripts

        # kpatch-build needs the whole env to be writeable, even the stuff
        # we just unpacked and copied
        chmod u+w . -R

        # command preview:
        echo kpatch-build -n ${patchName} '' +
      concatMapStringsSep " " (name: "${name}.patch") availablePatchesKpatchBuild +
      ''; # we dont get a newline between this and the next line; wtf
        # actual command
        $kpb/kpatch-build/kpatch-build -s src -n ${patchName} '' +
      concatMapStringsSep " " (name: "$src/${name}.patch") availablePatchesKpatchBuild +
      '' || ((tail -n 250 $CACHEDIR/build.log || echo log not found at $CACHEDIR/build.log) && exit 1)
      '';

      nativeBuildInputs = with pkgs; [ perl bc nettools openssl rsync gmp
                          libmpc mpfr gawk zstd elfutils cpio bison flex ];

      installModDir = "lib/modules/${kernel.modDirVersion}/extra";
      installModPath = "${installModDir}/${patchName}.ko";
      modDetectDir = "/sys/kernel/livepatch/" + builtins.replaceStrings ["-"] ["_"] patchName;
      installPhase = ''
        mkdir -p $out/${installModDir};
        cp ${patchName}.ko $out/${installModPath} || (ls -lah && exit 1)
        cat > $out/serviceContent <<serviceContent
[ -d ${modDetectDir} ] || insmod $out/${installModPath};
serviceContent
      '';

    };

  kpatchBuildPatches = pkgs.callPackage buildLivePatchKpatch { inherit availablePatchesKpatchBuild; };

  buildLivePatch = { patchName, stdenv }:
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

      patch = pkgs.callPackage buildLivePatch { inherit patchName; };

      ko = "${patch}/lib/modules/${kernel.modDirVersion}/extra/klp-${patchName}.ko";
    in
      "[ -d /sys/kernel/livepatch/${dirName} ] || insmod ${ko}*";

  manualServiceContent = concatMapStringsSep "\n" insmodLineGen availablePatchesManual;

  serviceContent = ''
    # Patches built with build-kpatch
    . ${kpatchBuildPatches}/serviceContent
    # Patches built using .c modules
    ${manualServiceContent}
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
    runit.services.live-patches = {
      run = optionalString (cfg.enable) serviceContent;
      oneShot = true;
      runlevels = [ "default" ];
    };
  };
}

