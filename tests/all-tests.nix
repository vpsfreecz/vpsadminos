{
  pkgs ? <nixpkgs>,
  system ? builtins.currentSystem
}:
let
  nixpkgs = import pkgs {};
  lib = nixpkgs.lib;

  distributions = import ./distributions.nix { inherit lib; };

  makeSingleTest = name:
    import (./suite + "/${name}.nix") { inherit pkgs system; };

  makeTemplateTest = { template, instances }:
    map (args:
      let
        t = import (./suite + "/${template}.nix") { templateArgs = args; inherit pkgs system; };
      in {
        name = "${template}@${t.instance}";
        value = {
          type = "template";
          template = template;
          args = args;
          test = t;
        };
      }
    ) instances;

  makeTest = v:
    if builtins.isAttrs v then
      makeTemplateTest v
    else
      {
        name = v;
        value = {
          type = "single";
          test = (makeSingleTest v);
        };
      };

  tests = list: builtins.listToAttrs (lib.flatten (map makeTest list));
in tests [
  "boot"
  "cgroups/devices-v1"
  { template = "cgroups/mount-v1"; instances = distributions.all ; }
  { template = "cgroups/mount-v2"; instances = distributions.cgroupv2; }
  "cgroups/system-v1"
  "cgroups/system-v2"
  "ctstartmenu/setup"
  { template = "dist-config/netif-routed"; instances = distributions.all; }
  { template = "dist-config/nonsystemd-rundir"; instances = distributions.non-systemd; }
  { template = "dist-config/start-stop"; instances = distributions.all; }
  { template = "dist-config/systemd-rundir"; instances = distributions.systemd; }
  "dist-config/systemd-rundir-limits"
  "docker/almalinux-8"
  "docker/alpine-latest"
  "docker/centos-7"
  "docker/debian-latest"
  "docker/fedora-latest"
  "docker/ubuntu-18.04"
  "docker/ubuntu-20.04"
  "docker/ubuntu-22.04"
  "driver"
  "lxcfs/loadavgs"
  { template = "lxcfs/overlays"; instances = distributions.all; }
  "osctl/ct-exec"
  "osctl/ct-mounts"
  "osctl/ct-runscript"
  "osctl/pool/export-cleanup"
  "osctl-exportfs/mount"
  "systemd/credentials"
  { template = "systemd/device-units"; instances = distributions.systemd; }
  "zfs/ugidmap"
  "zfs/xattr"
]
