{
  pkgs,
  lib ? pkgs.lib,
  stage,
  version ? null,
  modDirVersion ? null,
  features ? { },
}:

let
  makeKernel =
    {
      stage,
      version ? null,
      modDirVersion ? null,
      features ? { },
      kernelPatches ? [ ],
      randstructSeed ? "",
      ...
    }:
    let
      stageString = builtins.toString stage;
      stageOutPath = if builtins.isPath stage then stage + "/out" else /. + (stageString + "/out");
      stageDevInputPath =
        if builtins.isPath stage then stage + "/dev-input" else /. + (stageString + "/dev-input");
      meta = import (stageDevInputPath + "/meta.nix");
      kernelVersion = if version == null then meta.version else version;
      kernelModDirVersion = if modDirVersion == null then meta.modDirVersion else modDirVersion;
      configText = builtins.readFile (stageDevInputPath + "/config");
      configLines = lib.splitString "\n" configText;
      configValue =
        option:
        let
          key = "CONFIG_${option}";
          setPrefix = key + "=";
          unsetLine = "# ${key} is not set";
          setMatches = lib.filter (line: lib.hasPrefix setPrefix line) configLines;
          unset = lib.any (line: line == unsetLine) configLines;
          raw =
            if setMatches != [ ] then
              lib.removePrefix setPrefix (builtins.head setMatches)
            else if unset then
              "n"
            else
              null;
          unquoted =
            if raw != null && lib.hasPrefix "\"" raw && lib.hasSuffix "\"" raw then
              lib.removeSuffix "\"" (lib.removePrefix "\"" raw)
            else
              raw;
        in
        unquoted;
      kernelConfig = rec {
        isSet = option: configValue option != null;
        getValue = option: configValue option;
        isYes = option: getValue option == "y";
        isNo = option: getValue option == "n";
        isModule = option: getValue option == "m";
        isEnabled = option: isYes option || isModule option;
        isDisabled = option: (!isSet option) || isNo option;
      };
      kernelMakeFlags = [ "O=$(buildRoot)" ];
      kernelDev =
        pkgs.runCommand "linux-${kernelVersion}-local-dev-dev"
          {
            nativeBuildInputs = with pkgs; [
              bc
              bison
              elfutils
              flex
              gawk
              gnumake
              kmod
              libelf
              openssl
              pahole
              perl
              python3Minimal
              rsync
              stdenv.cc
              zlib
              zstd
            ];
            preferLocalBuild = true;
            allowSubstitutes = false;
          }
          ''
            set -eu

            moddir="${kernelModDirVersion}"
            src="$out/lib/modules/$moddir/source"
            build="$out/lib/modules/$moddir/build"

            mkdir -p "$src" "$build"
            cp -a --no-preserve=ownership ${stageDevInputPath}/source/. "$src"/
            cp ${stageDevInputPath}/config "$build/.config"
            cp ${stageDevInputPath}/Module.symvers "$build/Module.symvers"
            cp ${stageDevInputPath}/vmlinux "$out/vmlinux"

            patchShebangs "$src/scripts" "$src/tools/bpf"
            make -C "$src" O="$build" olddefconfig
            make -C "$src" O="$build" modules_prepare
            chmod u+w "$build/Module.symvers" 2>/dev/null || true
            cp ${stageDevInputPath}/Module.symvers "$build/Module.symvers"

            chmod -R u+w "$out"
            arch=$(cd "$build/arch"; ls)

            for d in "$src"/arch/*; do
              base=$(basename "$d")
              if [ "$base" = "$arch" ]; then
                continue
              fi
              if [ "$arch" = arm64 ] && [ "$base" = arm ]; then
                continue
              fi
              rm -rf "$d"
            done

            rm -rf "$src/drivers"

            find "$src" -type f -name '*.h' -print0 | xargs -0 -r chmod u-w
            find "$src" -type f -name '*.lds' -print0 | xargs -0 -r chmod u-w
            chmod u-w "$src/Makefile"
            chmod u-w "$src/arch/$arch"/Makefile*
            chmod u-w -R "$src/scripts"
            find "$src" -type f -perm -u=w -print0 | xargs -0 -r rm
            find "$src" -empty -type d -delete
          '';
    in
    assert builtins.pathExists (stageOutPath + "/bzImage");
    assert builtins.pathExists (stageOutPath + "/lib/modules/${kernelModDirVersion}/modules.dep");
    assert builtins.pathExists (stageDevInputPath + "/Module.symvers");
    pkgs.runCommand "linux-${kernelVersion}-local-dev"
      {
        makeFlags = kernelMakeFlags;
        preferLocalBuild = true;
        allowSubstitutes = false;
        passthru = {
          version = kernelVersion;
          modDirVersion = kernelModDirVersion;
          src = stageDevInputPath + "/source";
          config = kernelConfig;
          configfile = stageDevInputPath + "/config";
          inherit kernelPatches features randstructSeed;
          dev = kernelDev;
          moduleBuildDependencies = [ pkgs.libelf ];
          stdenv = pkgs.stdenv;
          commonMakeFlags = kernelMakeFlags;
          isZen = false;
          isHardened = false;
          isLibre = false;
          isXen = true;
          kernelOlder = lib.versionOlder kernelVersion;
          kernelAtLeast = lib.versionAtLeast kernelVersion;
        };
      }
      ''
        mkdir -p "$out"
        cp -a --no-preserve=ownership ${stageOutPath}/. "$out"/
      '';
in
lib.makeOverridable makeKernel {
  inherit
    stage
    version
    modDirVersion
    features
    ;
}
