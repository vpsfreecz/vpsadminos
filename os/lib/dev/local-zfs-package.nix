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
    if kernel != null then
      kernel.modDirVersion
    else
      meta.kernelModDirVersion or null;
  sourcePath =
    if kind == "kernel" then
      stagePath + "/kernel/out"
    else if kind == "user" then
      stagePath + "/user/out"
    else
      throw "unsupported local ZFS package kind: ${kind}";
  nameSuffix =
    if kind == "kernel" && kernelModDirVersion != null then
      "-${kernelModDirVersion}"
    else
      "";
in
assert kind != "kernel" || kernelModDirVersion != null;
assert kind != "kernel" || builtins.pathExists (
  sourcePath + "/lib/modules/${kernelModDirVersion}/extra/zfs.ko.xz"
);
assert kind != "kernel" || builtins.pathExists (
  sourcePath + "/lib/modules/${kernelModDirVersion}/extra/spl.ko.xz"
);
pkgs.runCommand "zfs-${kind}-${zfsVersion}-local-dev${nameSuffix}"
  {
    preferLocalBuild = true;
    allowSubstitutes = false;
    passthru = {
      inherit kind zfsVersion kernelModDirVersion;
    };
  }
  ''
    set -eu
    mkdir -p "$out"
    cp -a --no-preserve=ownership ${sourcePath}/. "$out"/
    chmod u+w "$out"

    if [ "${kind}" = kernel ]; then
      find "$out/lib/modules/${kernelModDirVersion}" -maxdepth 1 -type f -name 'modules.*' -delete
      mkdir -p "$out/nix-support"
      echo "${pkgs.util-linux}" >> "$out/nix-support/extra-refs"
    fi
  ''
