# This file provides compatibility for NixOS to run in a container on vpsAdminOS
# hosts.
#
# If you're experiencing issues, try updating this file to the latest version
# from vpsAdminOS repository:
#
#   https://github.com/vpsfreecz/vpsadminos/blob/staging/os/lib/nixos-container/stable/vpsadminos.nix

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
  services.resolved = mkDefault { fallbackDns = nameservers; };
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

  # Mount paths that are needed for boot (e.g. /var/lib/nixos) earlier.
  # This fixes UIDs and GIDs changing on reboot when using impermanence.
  # impermanence mounts them in the initrd, which doesn't exist in a container.
  boot.specialFileSystems =
    (lib.pipe config.fileSystems [
      # nixos supplies utils.fsNeededForBoot (also used by impermanence to find out which directories to mount early)
      # found here: https://github.com/nix-community/impermanence/blob/4b3e914cdf97a5b536a889e939fb2fd2b043a170/nixos.nix#L727
      (lib.filterAttrs (_: v: utils.fsNeededForBoot v))
      # config.boot.specialFileSystems only accepts a subset of the options from config.fileSystems
      # so filter out the rest.
      (builtins.mapAttrs (
        path: v:
        # throw a warning if some options not known by boot.specialFileSystems are set
        lib.warnIf (v.autoFormat || v.autoResize || v.encrypted.enable || v.overlay.workdir != null)
          "fileSystems.${path} has options set that are not supported by boot.specialFileSystems."

          # filter out the unknown options
          (lib.intersectAttrs (options.boot.specialFileSystems.type.getSubOptions { }) v)
      ))
    ])
    # this is here since 14937d20c0587f1c8a48f7f3a9bce7fcae255785 idk why it is needed
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
