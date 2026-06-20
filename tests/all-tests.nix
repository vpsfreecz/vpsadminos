{
  pkgs ? <nixpkgs>,
  system ? builtins.currentSystem,
  suiteArgs ? { },
  configuration ? null,
  testConfig ? { },
  testFramework ? null,
}:
let
  nixpkgs = import pkgs { inherit system; };
  lib = nixpkgs.lib;
  testLibArgs = {
    inherit
      pkgs
      system
      lib
      suiteArgs
      configuration
      testConfig
      ;
    suitePath = ./suite;
  };
  testLib =
    if testFramework == null then
      import ../test-runner/nix/lib.nix testLibArgs
    else
      testFramework.makeTestLib testLibArgs;

  distributions = import ./distributions.nix { inherit lib; };

  # Keep this list limited to kernels still running in the fleet. Repository
  # retention alone does not mean that a kernel needs current lifecycle CI.
  livepatchLifecycleInstances = [
    { kernelVersion = "6.12.95"; }
  ];

  imageScripts =
    let
      entriesAttrs = builtins.readDir ../image-scripts/images;

      scriptsAttrs = lib.filterAttrs (
        name: type:
        type == "symlink"
        || (type == "directory" && !(builtins.pathExists (../image-scripts/images + "/${name}/abstract")))
      ) entriesAttrs;

      scriptsList = lib.mapAttrsToList (name: type: { image-script = name; }) scriptsAttrs;
    in
    scriptsList;

  proactiveSwapEnabled = builtins.getEnv "VPSADMINOS_ENABLE_PROACTIVE_SWAP_TEST" == "1";
  proactiveSwapOnly = builtins.getEnv "VPSADMINOS_ONLY_PROACTIVE_SWAP_TEST" == "1";
  livepatchTestEnabled = builtins.getEnv "VPSADMINOS_ENABLE_LIVEPATCH_TEST" == "1";
  livepatchOnly = builtins.getEnv "VPSADMINOS_ONLY_LIVEPATCH_TEST" == "1";
  schedProxyExecEnabled = builtins.getEnv "VPSADMINOS_ENABLE_SCHED_PROXY_EXEC_TEST" == "1";
  schedProxyExecOnly = builtins.getEnv "VPSADMINOS_ONLY_SCHED_PROXY_EXEC_TEST" == "1";
  schedProxyExecLockBadneighborEnabled =
    builtins.getEnv "VPSADMINOS_ENABLE_SCHED_PROXY_EXEC_LOCK_BADNEIGHBOR_TEST" == "1";
  schedProxyExecLockBadneighborOnly =
    builtins.getEnv "VPSADMINOS_ONLY_SCHED_PROXY_EXEC_LOCK_BADNEIGHBOR_TEST" == "1";

  proactiveSwapTests =
    if proactiveSwapEnabled || proactiveSwapOnly then
      [
        "kernel/proactive-swap-cgroups-v1"
        "kernel/proactive-swap"
      ]
    else
      [ ];
  schedProxyExecTests =
    if schedProxyExecEnabled || schedProxyExecOnly then [ "kernel/sched-proxy-exec" ] else [ ];
  schedProxyExecLockBadneighborTests =
    if schedProxyExecLockBadneighborEnabled || schedProxyExecLockBadneighborOnly then
      [ "kernel/sched-proxy-exec-lock-badneighbor" ]
    else
      [ ];
  livepatchTests = if livepatchTestEnabled then [ "kernel/livepatch-6.12.95" ] else [ ];
  localOnlyTests = lib.unique (
    proactiveSwapTests ++ schedProxyExecTests ++ schedProxyExecLockBadneighborTests
  );

  selectedTests =
    if livepatchOnly then
      livepatchTests
    else if proactiveSwapOnly || schedProxyExecOnly || schedProxyExecLockBadneighborOnly then
      localOnlyTests
    else
      lib.unique (
        [
          "cgroups/devices-v1"
          "cgroups/devices-v2"
          {
            test = "cgroups/mount-v1";
            args = {
              distributions = distributions.cgroupAll ++ distributions.cgroupv1;
            };
          }
          {
            test = "cgroups/mount-v2";
            args = {
              distributions = distributions.cgroupAll ++ distributions.cgroupv2;
            };
          }
          {
            test = "cgroups/mount-v2-on-v1";
            args = {
              distributions = distributions.cgroupv2;
            };
          }
          "cgroups/system-v1"
          "cgroups/system-v2"
          "crashdump/default"
          "crashdump/inspect"
          "crashdump/nfs-inspect"
          "ctstartmenu/setup"
          "declarative-containers"
          "defaults"
          {
            test = "dist-config/netif-routed";
            args = {
              distributions = distributions.all;
            };
          }
          {
            test = "dist-config/nonsystemd-rundir";
            args = {
              distributions = distributions.non-systemd;
            };
          }
          {
            test = "dist-config/start-stop";
            args = {
              distributions = distributions.all;
            };
          }
          {
            test = "dist-config/systemd-rundir";
            args = {
              distributions = distributions.systemd;
            };
          }
          "dist-config/systemd-rundir-limits"
          "docker/almalinux"
          "docker/alpine"
          "docker/arch"
          "docker/debian"
          "docker/fedora"
          "docker/ubuntu"
          "driver/named-shells"
          "driver/nixos"
          "driver/parallel-test-scripts"
          "driver/rspec"
          "driver/vpsadminos"
          "ebpf-livepatch"
          "ebpf-livepatch-lifecycle"
          "firewall/conntrack"
          {
            template = "image-scripts/test";
            instances = imageScripts;
          }
          "incus/arch"
          "incus/debian"
          "incus/fedora"
          {
            template = "kernel/livepatch-lifecycle";
            instances = livepatchLifecycleInstances;
          }
          "kernel/vpsadminos"
          "kernel/module-autoload"
          "kernel/cpu-view/cgroups-v1"
          "kernel/cpu-view/cgroups-v2"
          "kernel/loadavg"
          "kernel/memory-view/cgroups-v1"
          "kernel/memory-view/cgroups-v2"
          "kernel/misc"
          "kernel/namespaces"
          "kernel/tracing-tools"
          "kernel/sched-proxy-exec-lock-badneighbor"
          "kernel/syslogns"
          "kernel/tmpfs/cgroups-v1"
          "kernel/tmpfs/cgroups-v2"
          "kernel/uptime"
          "kernel/vpsadminos-selftests"
          "osctl/ct-cat"
          "osctl/ct-chown-filecaps"
          "osctl/ct-console"
          "osctl/ct-exec-v1"
          "osctl/ct-exec-v2"
          "osctl/ct-image-fetch"
          "osctl/ct-local-transfer"
          "osctl/image-repository-build-service"
          "osctl/ct-map-mode"
          "osctl/ct-mounts"
          "osctl/ct-passwd"
          "osctl/ct-runscript-v1"
          "osctl/ct-runscript-v2"
          "osctl/ct-send-recv"
          "osctl/ct-uid-gid"
          "osctl/pool/export-cleanup"
          "osctl-exportfs/mount"
          "osctld/resilience"
          "osctld/restart"
          "prometheus/exporters"
          "podman/almalinux"
          "podman/arch"
          "podman/debian"
          "podman/fedora"
          "podman/ubuntu"
          "secrets"
          "snap/fedora"
          "snap/ubuntu"
          "system/boot/runit"
          "system/boot/stage-2"
          "system/install"
          "system/switch-to-configuration"
          "systemd/credentials"
          "systemd/ebpf"
          {
            test = "systemd/device-units";
            args = {
              distributions = distributions.systemd;
            };
          }
          "zfs/full-suite"
          "zfs/block-cloning-corruption"
          "zfs/fallocate-deadlock"
          "zfs/mmap-nosync"
          "zfs/overlayfs-deadlock"
          "zfs/ugidmap"
        ]
        ++ localOnlyTests
        ++ livepatchTests
      );
in
testLib.makeTests selectedTests
