{
  pkgs,
  lib ? pkgs.lib,
  stage,
  kind ? "kernel",
  kernel ? null,
  version ? null,
}:

let
  stageString = builtins.toString stage;
  stagePath = if builtins.isPath stage then stage else /. + stageString;
  meta = import (stagePath + "/meta.nix");
  zfsVersion = if version == null then (meta.version or "2.3-vpsadminos") else version;
  kernelModDirVersion =
    if kernel != null then kernel.modDirVersion else meta.kernelModDirVersion or null;
  sourcePath =
    if kind == "kernel" then
      stagePath + "/kernel/out"
    else if kind == "user" then
      stagePath + "/user/out"
    else
      throw "unsupported local ZFS package kind: ${kind}";
  nameSuffix =
    if kind == "kernel" && kernelModDirVersion != null then "-${kernelModDirVersion}" else "";
in
assert kind != "kernel" || kernelModDirVersion != null;
assert
  kind != "kernel"
  || builtins.pathExists (sourcePath + "/lib/modules/${kernelModDirVersion}/extra/zfs.ko.xz");
assert
  kind != "kernel"
  || builtins.pathExists (sourcePath + "/lib/modules/${kernelModDirVersion}/extra/spl.ko.xz");
pkgs.runCommand "zfs-${kind}-${zfsVersion}-local-dev${nameSuffix}"
  {
    preferLocalBuild = true;
    allowSubstitutes = false;
    nativeBuildInputs = lib.optionals (kind == "user") [ pkgs.autoPatchelfHook ];
    buildInputs = lib.optionals (kind == "user") (
      with pkgs;
      [
        attr
        curl
        eudev
        keyutils
        krb5
        libaio
        libcap
        libtirpc
        libunwind
        openssl
        pam
        stdenv.cc.cc.lib
        util-linux
        xz
        zlib
        zstd
      ]
    );
    passthru = {
      inherit kind zfsVersion kernelModDirVersion;
    };
  }
  ''
    set -eu
    mkdir -p "$out"
    cp -a --no-preserve=ownership ${sourcePath}/. "$out"/
    chmod -R u+w "$out"

    if [ "${kind}" = kernel ]; then
      find "$out/lib/modules/${kernelModDirVersion}" -maxdepth 1 -type f -name 'modules.*' -delete
      mkdir -p "$out/nix-support"
      echo "${pkgs.util-linux}" >> "$out/nix-support/extra-refs"
    else
      # vpsAdminOS exposes package /bin in the system and service PATH. Match
      # the regular ZFS package, which installs administrative commands there
      # and provides /sbin as a compatibility link.
      if [ -d "$out/sbin" ]; then
        for program in "$out"/sbin/*; do
          name="$(basename "$program")"
          if [ -e "$out/bin/$name" ]; then
            echo "staged ZFS program collision: $name" >&2
            exit 1
          fi
          mv "$program" "$out/bin/$name"
        done
        rmdir "$out/sbin"
      fi
      ln -s bin "$out/sbin"

      # The stage is produced outside of Nix and therefore contains host ELF
      # interpreters/RPATHs. autoPatchelfHook rewrites them against the target
      # closure. Udev rules likewise have to address helpers in this package,
      # not the target's nonexistent FHS /lib/udev directory.
      addAutoPatchelfSearchPath "$out/lib"
      substituteInPlace "$out/lib/udev/vdev_id" \
        --replace-fail "PATH=/bin:/sbin:/usr/bin:/usr/sbin" \
          "PATH=${
            lib.makeBinPath [
              pkgs.coreutils
              pkgs.gawk
              pkgs.gnused
              pkgs.gnugrep
            ]
          }"
      substituteInPlace "$out/lib/udev/rules.d/69-vdev.rules" \
        --replace-fail "/lib/udev/vdev_id" "$out/lib/udev/vdev_id"
      substituteInPlace "$out/lib/udev/rules.d/60-zvol.rules" \
        --replace-fail "/lib/udev/zvol_id" "$out/lib/udev/zvol_id"
      substituteInPlace "$out/share/zfs/common.sh" \
        --replace-fail "export BIN_DIR=//bin" "export BIN_DIR=$out/bin" \
        --replace-fail "export SBIN_DIR=//sbin" "export SBIN_DIR=$out/sbin" \
        --replace-fail "export LIBEXEC_DIR=/libexec/zfs" "export LIBEXEC_DIR=$out/libexec/zfs" \
        --replace-fail "export ZTS_DIR=//share/zfs" "export ZTS_DIR=$out/share/zfs" \
        --replace-fail "export SCRIPT_DIR=//share/zfs" "export SCRIPT_DIR=$out/share/zfs"
      if [ -f "$out/share/zfs/zfs-tests/include/default.cfg" ]; then
        substituteInPlace "$out/share/zfs/zfs-tests/include/default.cfg" \
          --replace-fail \
            ':-/libexec/zfs/zed.d' \
            ":-$out/libexec/zfs/zed.d" \
          --replace-fail \
            ':-//share/zfs/compatibility.d' \
            ":-$out/share/zfs/compatibility.d"
      fi
      if [ -x "$out/share/zfs/zfs-tests/bin/mmap_libaio" ]; then
        patchelf \
          --replace-needed libaio.so.1t64 libaio.so.1 \
          "$out/share/zfs/zfs-tests/bin/mmap_libaio"
      fi
      autoPatchelf "$out"

      if ! patchelf --print-needed "$out/bin/zed" | grep -qx 'libudev.so.1'; then
        echo "staged ZFS zed has no libudev support" >&2
        exit 1
      fi

      # libzfs loads curl with dlopen(), so autoPatchelf cannot discover it.
      # Keep the dynamic dependency in the adapted package's runtime closure.
      libzfs=$(find "$out/lib" -maxdepth 1 -type f -name 'libzfs.so.*' -print -quit)
      if [ -z "$libzfs" ]; then
        echo "staged ZFS package has no versioned libzfs shared object" >&2
        exit 1
      fi
      patchelf --add-rpath "${lib.makeLibraryPath [ pkgs.curl ]}" "$libzfs"
    fi
  ''
