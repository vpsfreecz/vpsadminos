{
  pkgs ? <nixpkgs>,
  system ? builtins.currentSystem
}:
let
  nixpkgs = import pkgs {};
  lib = nixpkgs.lib;

  distributions = import ./distributions.nix { inherit lib; };

  imageScripts =
    let
      entriesAttrs = builtins.readDir ../image-scripts/images;

      scriptsAttrs = lib.filterAttrs (name: type:
        type == "symlink" || (type == "directory" && !(builtins.pathExists (../image-scripts/images + "/${name}/abstract")))
      ) entriesAttrs;

      scriptsList = lib.mapAttrsToList (name: type: { image-script = name; }) scriptsAttrs;
    in scriptsList;

  makeSingleTest = { test, args ? {} }: {
    name = test;
    value = {
      type = "single";
      test = import (./suite + "/${test}.nix") { inherit pkgs system; testArgs = args; };
      testArgs = args;
    };
  };

  makeTemplateTest = { template, instances }:
    map (args:
      let
        t = import (./suite + "/${template}.nix") { templateArgs = args; inherit pkgs system; };
      in {
        name = "${template}@${t.instance}";
        value = {
          type = "template";
          template = template;
          templateArgs = args;
          test = t;
        };
      }
    ) instances;

  makeTest = v:
    if builtins.isAttrs v then
      if builtins.hasAttr "template" v then
        makeTemplateTest v
      else makeSingleTest v
    else makeSingleTest { test = v; };

  tests = list: builtins.listToAttrs (lib.flatten (map makeTest list));
in tests [
  "boot"
  "cgroups/devices-v1"
  "cgroups/devices-v2"
  { template = "cgroups/mount-v1"; instances = distributions.all ; }
  { template = "cgroups/mount-v2"; instances = distributions.cgroupv2; }
  "cgroups/system-v1"
  "cgroups/system-v2"
  "ctstartmenu/setup"
  "defaults"
  { template = "dist-config/netif-routed"; instances = distributions.all; }
  { template = "dist-config/nonsystemd-rundir"; instances = distributions.non-systemd; }
  { template = "dist-config/start-stop"; instances = distributions.all; }
  { template = "dist-config/systemd-rundir"; instances = distributions.systemd; }
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
  { template = "image-scripts/test"; instances = imageScripts; }
  "osctl/ct-cat"
  "osctl/ct-exec-v1"
  "osctl/ct-exec-v2"
  "osctl/ct-map-mode"
  "osctl/ct-mounts"
  "osctl/ct-runscript-v1"
  "osctl/ct-runscript-v2"
  "osctl/pool/export-cleanup"
  "osctl-exportfs/mount"
  "podman/debian-latest"
  "podman/fedora-latest"
  "podman/ubuntu-latest"
  "snap/hello-fedora"
  "snap/hello-ubuntu"
  "snap/lxd-fedora"
  "snap/lxd-ubuntu"
  "systemd/credentials"
  { template = "systemd/device-units"; instances = distributions.systemd; }
  "zfs/ugidmap"
  "zfs/xattr"
]
