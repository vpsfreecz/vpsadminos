{ config, pkgs, lib, ... }:
let
  kernelPackages = import ../packages/linux/packages.nix {
    inherit config lib pkgs;
  };

  linuxSnapshot = builtins.getEnv "VPSADMINOS_LINUX_SNAPSHOT";
  kernelVersionEnv = builtins.getEnv "VPSADMINOS_PROACTIVE_SWAP_KERNEL_VERSION";
  diskPathEnv = builtins.getEnv "VPSADMINOS_PROACTIVE_SWAP_DISK";

  kernelVersion = if kernelVersionEnv == "" then "6.12.81" else kernelVersionEnv;
  diskPath = if diskPathEnv == "" then "/root/ai/tmp/proactive-swap-sda.img" else diskPathEnv;

  localKernel =
    if linuxSnapshot == "" then
      null
    else
      pkgs.callPackage ../packages/linux/generic.nix (rec {
        version = kernelVersion;
        modDirVersion = lib.concatStringsSep "." (lib.take 3 (lib.splitString "." "${version}.0"));
        extraMeta.branch = lib.concatStringsSep "." (lib.take 2 (lib.splitString "." version));
        src = /. + linuxSnapshot;
        kernelPatches = [ pkgs.kernelPatches.bridge_stp_helper ];
        structuredExtraConfig = with lib.kernel; {
          DAMON = yes;
          DAMON_VADDR = yes;
          DAMON_PADDR = yes;
          DAMON_SYSFS = yes;
          DAMON_RECLAIM = yes;
        };
        features =
          if builtins.hasAttr "features" kernelPackages.kernels.${version} then
            kernelPackages.kernels.${version}.features
          else
            { };
        zfsBuiltinPkg = null;
      });
in
{
  boot.kernelVersion = lib.mkForce kernelVersion;
  boot.kernelPackage =
    lib.mkForce (
      if localKernel != null then
        localKernel
      else
        kernelPackages.genKernelPackage kernelVersion
    );
  boot.zfsBuiltin = lib.mkForce false;

  boot.qemu.disks = lib.mkForce [
    {
      device = diskPath;
      type = "file";
      size = "16G";
      create = true;
    }
  ];
  boot.qemu.memory = lib.mkForce 4096;
  boot.qemu.cpus = lib.mkForce 4;
  boot.qemu.cpu.cores = lib.mkForce 4;
  boot.qemu.cpu.sockets = lib.mkForce 1;

  boot.damon.reclaim = {
    enable = true;
    quota.freeMemBytes = 536870912;
    quota.ms = 50;
    quota.size = 268435456;
    quota.resetIntervalMs = 1000;
    watermarks.high = 1000;
    watermarks.mid = 900;
    watermarks.low = 0;
  };

  runit.services.proactive-swap-smoke = {
    path = [
      pkgs.coreutils
      pkgs.util-linux
    ];

    run = ''
      waitForService damon-reclaim 120

      params=/sys/module/damon_reclaim/parameters

      show_param() {
        name="$1"
        path="$params/$name"

        if [ -e "$path" ]; then
          echo "PROACTIVE_SWAP_SMOKE $name=$(cat "$path")" > /dev/console
        else
          echo "PROACTIVE_SWAP_SMOKE $name=MISSING" > /dev/console
        fi
      }

      echo "PROACTIVE_SWAP_SMOKE begin" > /dev/console
      echo "PROACTIVE_SWAP_SMOKE uname=$(uname -r)" > /dev/console
      if [ -d "$params" ]; then
        echo "PROACTIVE_SWAP_SMOKE param_files=$(ls "$params" | tr '\n' ',')" > /dev/console
      else
        echo "PROACTIVE_SWAP_SMOKE param_dir=MISSING" > /dev/console
      fi
      show_param enabled
      show_param quota_free_mem_bytes
      show_param quota_free_mem_rate
      show_param kdamond_pid
      echo "PROACTIVE_SWAP_SMOKE end" > /dev/console

      exec poweroff -f
    '';

    oneShot = true;
    onChange = "ignore";
    log.enable = true;
    log.sendTo = "127.0.0.1";
  };
}
