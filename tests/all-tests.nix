{
  pkgs ? <nixpkgs>,
  system ? builtins.currentSystem,
  suiteArgs ? { },
}:
let
  nixpkgs = import pkgs { inherit system; };
  lib = nixpkgs.lib;
  testLib = import ../test-runner/nix/lib.nix {
    inherit
      pkgs
      system
      lib
      suiteArgs
      ;
    suitePath = ./suite;
  };

  distributions = import ./distributions.nix { inherit lib; };

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
in
testLib.makeTests [
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
  "crashdump"
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
  "docker/almalinux-8"
  "docker/almalinux-9"
  "docker/almalinux-10"
  "docker/alpine-latest"
  "docker/arch-latest"
  "docker/debian-latest"
  "docker/fedora-latest"
  "docker/ubuntu-20.04"
  "docker/ubuntu-22.04"
  "docker/ubuntu-24.04"
  "driver/nixos"
  "driver/rspec"
  "driver/vpsadminos"
  {
    template = "image-scripts/test";
    instances = imageScripts;
  }
  "kernel/cpu-view/cgroups-v1"
  "kernel/cpu-view/cgroups-v2"
  "kernel/loadavg"
  "kernel/memory-view/cgroups-v1"
  "kernel/memory-view/cgroups-v2"
  "kernel/misc"
  "kernel/syslogns"
  "kernel/tmpfs/cgroups-v1"
  "kernel/tmpfs/cgroups-v2"
  "kernel/uptime"
  "osctl/ct-cat"
  "osctl/ct-exec-v1"
  "osctl/ct-exec-v2"
  "osctl/ct-map-mode"
  "osctl/ct-mounts"
  "osctl/ct-runscript-v1"
  "osctl/ct-runscript-v2"
  "osctl/ct-send-recv"
  "osctl/ct-uid-gid"
  "osctl/pool/export-cleanup"
  "osctl-exportfs/mount"
  "podman/debian-latest"
  "podman/fedora-latest"
  "podman/ubuntu-latest"
  "secrets"
  "snap/hello-fedora"
  "snap/hello-ubuntu"
  "snap/lxd-fedora"
  "snap/lxd-ubuntu"
  "systemd/credentials"
  {
    test = "systemd/device-units";
    args = {
      distributions = distributions.systemd;
    };
  }
  "zfs/mmap-nosync"
  "zfs/overlayfs-deadlock"
  "zfs/ugidmap"
]
