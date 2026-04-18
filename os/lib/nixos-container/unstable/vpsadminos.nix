# This file provides compatibility for NixOS to run in a container on vpsAdminOS
# hosts.
#
# If you're experiencing issues, try updating this file to the latest version
# from vpsAdminOS repository:
#
#   https://github.com/vpsfreecz/vpsadminos/blob/staging/os/lib/nixos-container/unstable/vpsadminos.nix

{
  config,
  lib,
  options,
  pkgs,
  utils,
  ...
}:
let
  inherit (lib)
    mkDefault
    mkOverride
    mkForce
    ;

  nameservers = [
    "1.1.1.1"
    "2606:4700:4700::1111"
  ];
in
{
  networking.nameservers = mkDefault nameservers;
  services.resolved.settings.Resolve = mkDefault { FallbackDNS = nameservers; };
  networking.dhcpcd.extraConfig = "noipv4ll";

  systemd.services.systemd-oomd.enable = false;
  systemd.sockets."systemd-journald-audit".enable = false;
  systemd.mounts = [
    {
      where = "/sys/kernel/debug";
      enable = false;
    }
  ];
  systemd.services.rpc-gssd.enable = false;

  # Needed for systemd since v258, see issue #39036
  systemd.services.console-getty.serviceConfig = {
    StandardInput = "null";
    StandardOutput = "null";
  };

  # Due to our restrictions in /sys, the default systemd-udev-trigger fails
  # on accessing PCI devices, etc. Override it to match only network devices.
  # In addition, boot.isContainer prevents systemd-udev-trigger.service from
  # being enabled at all, so add it explicitly.
  systemd.additionalUpstreamSystemUnits = [
    "systemd-udev-trigger.service"
  ];
  systemd.services.systemd-udev-trigger.serviceConfig.ExecStart = [
    ""
    "-udevadm trigger --subsystem-match=net --action=add"
  ];

  boot.isContainer = true;
  boot.enableContainers = mkDefault true;
  boot.loader.initScript.enable = true;
  boot.systemdExecutable = mkDefault "/run/current-system/systemd/lib/systemd/systemd systemd.unified_cgroup_hierarchy=0";
  console.enable = true;

  # Mount paths that are needed for boot (e.g. /persistent and /var/lib/nixos)
  # earlier. This fixes UIDs and GIDs changing on reboot when using
  # impermanence.
  #
  # In a VM or on bare metal, impermanence mounts boot-critical bind mounts in
  # the initrd. vpsAdminOS containers do not have an initrd, so replay those
  # mounts through boot.specialFileSystems before activation runs.
  boot.specialFileSystems =
    let
      bootSpecialFileSystemOpts = options.boot.specialFileSystems.type.getSubOptions { };

      bootNeededFileSystems = lib.pipe config.fileSystems [
        (lib.filterAttrs (_: v: utils.fsNeededForBoot v))
        (builtins.mapAttrs (
          path: v:
          lib.warnIf (v.autoFormat || v.autoResize || v.encrypted.enable || v.overlay.workdir != null)
            "fileSystems.${path} has options set that are not supported by boot.specialFileSystems."
            (lib.intersectAttrs bootSpecialFileSystemOpts v)
        ))
      ];

      bootNeededBindMounts = builtins.listToAttrs (
        builtins.map
          (mount: {
            name = mount.where;
            value = lib.intersectAttrs bootSpecialFileSystemOpts {
              device = mount.what;
              fsType = mount.type or "none";
              options = lib.splitString "," (mount.options or "");
            };
          })
          (
            lib.filter (
              mount:
              (mount.enable or true)
              && mount ? where
              && mount ? what
              && (mount.type or null) == "none"
              && builtins.elem "bind" (lib.splitString "," (mount.options or ""))
              && builtins.elem mount.where utils.pathsNeededForBoot
            ) config.systemd.mounts
          )
      );
    in
    bootNeededFileSystems
    // bootNeededBindMounts
    // {
      "/run/keys".fsType = mkForce "tmpfs";
    };

  # Overrides for <nixpkgs/nixos/modules/virtualisation/container-config.nix>
  documentation.enable = mkOverride 500 true;
  documentation.nixos.enable = mkOverride 500 true;
  networking.useHostResolvConf = mkOverride 500 false;
  services.openssh.startWhenNeeded = mkOverride 500 false;

  # Bring up the network, /ifcfg.{add,del} are supplied by the vpsAdminOS host
  systemd.services.networking-setup = {
    description = "Load network configuration provided by the vpsAdminOS host";
    before = [ "network.target" ];
    wantedBy = [ "network.target" ];
    after = [ "network-pre.target" ];
    path = [ pkgs.iproute2 ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.bash}/bin/bash /ifcfg.add";
      ExecStop = "${pkgs.bash}/bin/bash /ifcfg.del";
    };
    unitConfig.ConditionPathExists = "/ifcfg.add";
    restartIfChanged = false;
  };
}
