# Provide an initial copy of the NixOS/vpsAdminOS channel(s) so that the user
# doesn't need to run "nix-channel --update" first.

{ config, lib, pkgs, ... }:

with lib;

let
  nixpkgs = lib.cleanSource pkgs.path;
  os = (builtins.filterSource (p: t:
    lib.cleanSourceFilter p t
    && (!lib.hasSuffix "img" (baseNameOf p))
    && (baseNameOf p != "local.nix")
    ) ../../.);

  # We need a copy of the Nix expressions for Nixpkgs and vpsAdminOS on the
  # CD. These are installed as "nixos/nixpkgs" and "vpsadminos" channels
  # of the root user, as expected by os-rebuild/os-install.
  channelSources = pkgs.runCommand "vpsadminos-${config.system.osVersion}"
    { }
    ''
      mkdir -p $out
      cp -prd ${nixpkgs} $out/nixos
      cp -prd ${os} $out/vpsadminos
      chmod -R u+w $out/nixos
      chmod -R u+w $out/vpsadminos
      if [ ! -e $out/nixos/nixpkgs ]; then
        ln -s . $out/nixos/nixpkgs
      fi
      echo -n ${config.system.osRevision} > $out/vpsadminos/.git-revision
      echo -n ${config.system.osVersionSuffix} > $out/vpsadminos/.version-suffix
      echo ${config.system.osVersionSuffix} | sed -e s/pre// > $out/vpsadminos/svn-revision
    '';

in

{
  # Provide the vpsAdminOS/Nixpkgs sources. This is required
  # for os-install.
  runit.services.channel-registration = {
    run = ''
      sv check eudev-trigger >/dev/null || exit 1
      set -e
      if ! [ -e /var/lib/nixos/did-channel-init ]; then
        echo "unpacking the NixOS/Nixpkgs sources..."
        mkdir -p /nix/var/nix/profiles/per-user/root
        ${config.nix.package.out}/bin/nix-env -p /nix/var/nix/profiles/per-user/root/channels \
          -i ${channelSources} --quiet --option build-use-substitutes false
        mkdir -m 0700 -p /root/.nix-defexpr
        ln -s /nix/var/nix/profiles/per-user/root/channels /root/.nix-defexpr/channels
        mkdir -m 0755 -p /var/lib/nixos
        touch /var/lib/nixos/did-channel-init
      fi
    '';
    oneShot = true;
  };
}
