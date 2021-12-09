# This file provides compatibility for NixOS to run in a container on vpsAdminOS
# hosts.
#
# If you're experiencing issues, try updating this file to the latest version
# from vpsAdminOS repository:
#
#   https://github.com/vpsfreecz/vpsadminos/blob/staging/os/lib/nixos-container/vpsadminos.nix

{ config, pkgs, lib, ...}:
with lib;
let
  nameservers = [
    "1.1.1.1"
    "2606:4700:4700::1111"
  ];
in {
  networking.nameservers = lib.mkDefault nameservers;
  services.resolved = lib.mkDefault { fallbackDns = nameservers; };
  networking.dhcpcd.extraConfig = "noipv4ll";

  systemd.services.systemd-sysctl.enable = false;
  systemd.sockets."systemd-journald-audit".enable = false;
  systemd.mounts = [ {where = "/sys/kernel/debug"; enable = false;} ];
  systemd.services.systemd-udev-trigger.enable = false;
  systemd.services.rpc-gssd.enable = false;

  boot.isContainer = true;
  boot.enableContainers = mkDefault true;
  boot.loader.initScript.enable = true;
  boot.specialFileSystems."/run/keys".fsType = lib.mkForce "tmpfs";
  boot.systemdExecutable = mkDefault "systemd systemd.unified_cgroup_hierarchy=0";

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
    path = [ pkgs.iproute ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.bash}/bin/bash /ifcfg.add";
      ExecStop = "${pkgs.bash}/bin/bash /ifcfg.del";
    };
    unitConfig.ConditionPathExists = "/ifcfg.add";
  };
}
