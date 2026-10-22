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
    {
      kernelVersion = "6.12.95";
      predecessorVariant = "v5";
    }
    {
      kernelVersion = "6.12.95";
      predecessorVariant = "v6";
    }
    { kernelVersion = "6.12.110"; }
  ];

  livepatchQualificationInstances =
    lib.concatMap
      (
        shape:
        map (predecessor: shape // { inherit predecessor; }) [
          "v5"
          "v6"
        ]
      )
      [
        {
          vendor = "amd";
          profile = "scale-aged";
        }
        {
          vendor = "amd";
          profile = "low-memory";
        }
        {
          vendor = "intel";
          profile = "representative";
        }
        {
          vendor = "amd";
          profile = "retention";
        }
        {
          vendor = "intel";
          profile = "retention";
        }
      ]
    ++
      lib.concatMap
        (
          predecessor:
          map (iteration: {
            vendor = "amd";
            profile = "fresh";
            inherit predecessor iteration;
          }) (lib.range 1 10)
        )
        [
          "v5"
          "v6"
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

  livepatchTestEnabled = builtins.getEnv "VPSADMINOS_ENABLE_LIVEPATCH_TEST" == "1";
  livepatchOnly = builtins.getEnv "VPSADMINOS_ONLY_LIVEPATCH_TEST" == "1";
  nfsTransitionTestEnabled =
    livepatchTestEnabled || builtins.getEnv "VPSADMINOS_LIVEPATCH_SINGLE_SERIES_MODULE" != "";
  sctpHostileTestEnabled = nfsTransitionTestEnabled;
  schedProxyExecEnabled = builtins.getEnv "VPSADMINOS_ENABLE_SCHED_PROXY_EXEC_TEST" == "1";
  schedProxyExecOnly = builtins.getEnv "VPSADMINOS_ONLY_SCHED_PROXY_EXEC_TEST" == "1";
  schedProxyExecLockBadneighborEnabled =
    builtins.getEnv "VPSADMINOS_ENABLE_SCHED_PROXY_EXEC_LOCK_BADNEIGHBOR_TEST" == "1";
  schedProxyExecLockBadneighborOnly =
    builtins.getEnv "VPSADMINOS_ONLY_SCHED_PROXY_EXEC_LOCK_BADNEIGHBOR_TEST" == "1";

  schedProxyExecTests =
    if schedProxyExecEnabled || schedProxyExecOnly then [ "kernel/sched-proxy-exec" ] else [ ];
  schedProxyExecLockBadneighborTests =
    if schedProxyExecLockBadneighborEnabled || schedProxyExecLockBadneighborOnly then
      [ "kernel/sched-proxy-exec-lock-badneighbor" ]
    else
      [ ];
  livepatchTests =
    if livepatchTestEnabled then
      [
        "kernel/livepatch-6.12.95"
        "kernel/livepatch-perf-v7"
        "kernel/livepatch-tun-intel"
        "kernel/livepatch-sctp-baseline"
        "kernel/livepatch-inet-frag"
        "osctl/nfs-cancellation-baseline"
        {
          template = "kernel/livepatch-qualification";
          instances = livepatchQualificationInstances;
        }
      ]
    else
      [ ];
  nfsTransitionTests =
    if nfsTransitionTestEnabled then [ "kernel/livepatch-nfs-transition" ] else [ ];
  sctpHostileTests = if sctpHostileTestEnabled then [ "kernel/livepatch-sctp-hostile" ] else [ ];
  localOnlyTests = lib.unique (schedProxyExecTests ++ schedProxyExecLockBadneighborTests);

  selectedTests =
    if livepatchOnly then
      livepatchTests ++ nfsTransitionTests ++ sctpHostileTests
    else if schedProxyExecOnly || schedProxyExecLockBadneighborOnly then
      localOnlyTests
    else
      lib.unique (
        [
          "upgrade/from-6.12"
          "upgrade/from-6.12-guests"
          "upgrade/from-6.12-guests-v1"
          "upgrade/from-6.12-inherited-guests"
          "upgrade/from-6.12-management-ops"
          "upgrade/from-6.12-v1"
          "upgrade/from-6.12-via-6.18"
          "upgrade/from-6.12-via-6.18-v1"
          "upgrade/from-6.18"
          "upgrade/from-6.18-consumers"
          "upgrade/from-6.18-consumers-v1"
          "upgrade/from-6.18-frozen"
          "upgrade/from-6.18-guests"
          "upgrade/from-6.18-guests-v1"
          "upgrade/from-6.18-map-pools"
          "upgrade/from-6.18-mapping"
          "upgrade/from-6.18-nested-docker"
          "upgrade/from-6.18-nested-incus"
          "upgrade/from-6.18-netif"
          "upgrade/from-6.18-networkd"
          "upgrade/from-6.18-nested-podman"
          "upgrade/from-6.18-pre-mount"
          "upgrade/from-6.18-v1"
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
          "dist-config/netif-bridge"
          "dist-config/nixos-resolvers"
          "dist-config/nixos-persistence-upgrade"
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
          "driver/disk-preservation"
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
          "kernel/livepatch-kernel-identity"
          "kernel/module-autoload"
          "kernel/cpu-view/cgroups-v1"
          "kernel/cpu-view/cgroups-v2"
          "kernel/loadavg"
          "kernel/memory-view/cgroups-v1"
          "kernel/memory-view/cgroups-v2"
          "kernel/misc"
          "kernel/namespaces"
          "kernel/netns-preinit-fault"
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
          "osctl/ct-mounts-races"
          "osctl/ct-passwd"
          "osctl/ct-runscript-v1"
          "osctl/ct-runscript-v2"
          "osctl/ct-transient-failures-v1"
          "osctl/ct-transient-failures-v2"
          "osctl/ct-send-recv"
          "osctl/ct-uid-gid"
          "osctl/nfs-cancellation"
          "osctl/nfs-cancellation-native110"
          "osctl/pool/export-cleanup"
          "osctl-exportfs/mount"
          "osctld/direct-start"
          "osctld/resilience"
          "osctld/restart"
          "osctld/switch-user-prlimits"
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
          "system/install-zfs"
          "system/switch-to-configuration"
          "system/sysctl"
          "systemd/credentials"
          "systemd/ebpf"
          {
            test = "systemd/device-units";
            args = {
              distributions = distributions.systemd;
            };
          }
          "zfs/full-suite"
          "zfs/boot-modes"
          "zfs/block-cloning-corruption"
          "zfs/fallocate-deadlock"
          "zfs/large-folios"
          "zfs/mmap-nosync"
          "zfs/mmap-write-truncate"
          "zfs/overlayfs-deadlock"
          "zfs/ugidmap"
        ]
        ++ localOnlyTests
        ++ livepatchTests
        ++ nfsTransitionTests
        ++ sctpHostileTests
      );
in
testLib.makeTests selectedTests
