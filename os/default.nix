{ configuration ? import ./configs/common.nix, nixpkgs ? <nixpkgs>, extraModules ? [], system ? builtins.currentSystem, platform ? null, vpsadmin ? null }:

let
  pkgs = import nixpkgs { inherit system; platform = platform; config = {}; };
  pkgsModule = rec {
    _file = ./default.nix;
    key = _file;
    config = {
      nixpkgs.system = pkgs.lib.mkDefault system;
      nixpkgs.overlays = import ./overlays.nix { lib = pkgs.lib; inherit vpsadmin; };
    };
  };
  baseModules = [
      ./base.nix
      ./system-path.nix
      ./stage-1.nix
      ./stage-2.nix
      ./runit.nix
      ./modules/bird.nix
      ./modules/containers.nix
      ./modules/eudev.nix
      ./modules/nfs.nix
      ./modules/node_exporter.nix
      ./modules/rpcbind.nix
      ./modules/tty.nix
      ./modules/zfs.nix
      ./modules/version.nix
      (nixpkgs + "/nixos/modules/misc/extra-arguments.nix")
      (nixpkgs + "/nixos/modules/system/etc/etc.nix")
      (nixpkgs + "/nixos/modules/system/activation/activation-script.nix")
      (nixpkgs + "/nixos/modules/system/boot/modprobe.nix")
      (nixpkgs + "/nixos/modules/misc/nixpkgs.nix")
      (nixpkgs + "/nixos/modules/config/swap.nix")
      (nixpkgs + "/nixos/modules/config/shells-environment.nix")
      (nixpkgs + "/nixos/modules/config/system-environment.nix")
      (nixpkgs + "/nixos/modules/tasks/filesystems.nix")
#     (nixpkgs + "/nixos/modules/tasks/filesystems/zfs.nix")
#                                                  ^ we use custom, minimal zfs.nix implementation
      (nixpkgs + "/nixos/modules/programs/bash/bash.nix")
      (nixpkgs + "/nixos/modules/programs/shadow.nix")
      (nixpkgs + "/nixos/modules/programs/environment.nix")
      (nixpkgs + "/nixos/modules/security/ca.nix")
      (nixpkgs + "/nixos/modules/security/apparmor.nix")
      (nixpkgs + "/nixos/modules/security/pam.nix")
      (nixpkgs + "/nixos/modules/config/ldap.nix")
      (nixpkgs + "/nixos/modules/config/nsswitch.nix")
      (nixpkgs + "/nixos/modules/misc/ids.nix")
      (nixpkgs + "/nixos/modules/virtualisation/lxc.nix")
      (nixpkgs + "/nixos/modules/virtualisation/lxcfs.nix")
      (nixpkgs + "/nixos/modules/services/networking/dhcpd.nix")
      <nixpkgs/nixos/modules/services/networking/ssh/sshd.nix>
      <nixpkgs/nixos/modules/system/boot/kernel.nix>
      <nixpkgs/nixos/modules/misc/assertions.nix>
      <nixpkgs/nixos/modules/misc/lib.nix>
      <nixpkgs/nixos/modules/config/sysctl.nix>
      <nixpkgs/nixos/modules/config/users-groups.nix>
      <nixpkgs/nixos/modules/config/i18n.nix>
      ./modules/rename.nix
      ./ipxe.nix
      ./nixos-compat.nix
      pkgsModule
  ] ++ pkgs.lib.optionals (vpsadmin != null && pkgs.lib.pathExists vpsadmin) [./modules/vpsadmin.nix];
  evalConfig = modules: pkgs.lib.evalModules {
    prefix = [];
    check = true;
    modules = modules ++ baseModules ++ [ pkgsModule ] ++ extraModules;
    args = {};
  };
in
rec {
  test1 = evalConfig [
    configuration
  ];
  runner = test1.config.system.build.runvm;
  config = test1.config;
}
