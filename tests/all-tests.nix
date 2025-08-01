{
  pkgs ? <nixpkgs>,
  system ? builtins.currentSystem,
}:
let
  nixpkgs = import pkgs { };
  lib = nixpkgs.lib;

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

  makeSingleTest =
    {
      test,
      args ? { },
    }:
    {
      name = test;
      value = {
        type = "single";
        test = import (./suite + "/${test}.nix") {
          inherit pkgs system;
          testArgs = args;
        };
        testArgs = args;
      };
    };

  makeTemplateTest =
    { template, instances }:
    map (
      args:
      let
        t = import (./suite + "/${template}.nix") {
          templateArgs = args;
          inherit pkgs system;
        };
      in
      {
        name = "${template}@${t.instance}";
        value = {
          type = "template";
          template = template;
          templateArgs = args;
          test = t;
        };
      }
    ) instances;

  makeTest =
    v:
    if builtins.isAttrs v then
      if builtins.hasAttr "template" v then makeTemplateTest v else makeSingleTest v
    else
      makeSingleTest { test = v; };

  tests = list: builtins.listToAttrs (lib.flatten (map makeTest list));
in
tests [
  "cgroups/devices-v1"
  "cgroups/devices-v2"
  {
    test = "cgroups/mount-v1";
    args = {
      distributions = distributions.all;
    };
  }
  {
    test = "cgroups/mount-v2";
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
  "driver"
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
