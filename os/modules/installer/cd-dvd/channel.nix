# Provide an initial copy of the NixOS/vpsAdminOS channel(s) so that the user
# doesn't need to run "nix-channel --update" first.

{ config, lib, pkgs, ... }:

with lib;

let
  nixpkgs = lib.cleanSource pkgs.path;

  os = (builtins.filterSource (path: type:
    (lib.cleanSourceFilter path type)
    && (!lib.hasSuffix "img" (baseNameOf path))
    && (!hasInfix "/os/result/" path)
    && (baseNameOf path != "local.nix")
  ) ../../../.);

  ctStartMenu = builtins.filterSource (path: type:
    (lib.cleanSourceFilter path type)
    && (baseNameOf path != "ctstartmenu") # exclude the locally-built binary
  ) ../../../../ctstartmenu;

  # We need a copy of the Nix expressions for Nixpkgs and vpsAdminOS on the
  # CD. These are installed as "nixos/nixpkgs" and "vpsadminos" channels
  # of the root user, as expected by os-rebuild/os-install.
  channelSources = pkgs.runCommand "vpsadminos-${config.system.vpsadminos.version}"
    { }
    ''
      mkdir -p $out $out/vpsadminos $out/vpsadminos/artwork
      cp -prd ${nixpkgs} $out/nixos
      cp -prd ${ctStartMenu} $out/vpsadminos/ctstartmenu
      cp -prd ${os} $out/vpsadminos/os
      cp -prd ${../../../../artwork/boot.png} $out/vpsadminos/artwork/boot.png
      chmod -R u+w $out/nixos
      chmod -R u+w $out/vpsadminos
      if [ ! -e $out/nixos/nixpkgs ]; then
        ln -s . $out/nixos/nixpkgs
      fi
      echo -n ${config.system.vpsadminos.release} > $out/vpsadminos/.version
      echo -n ${config.system.vpsadminos.versionSuffix} > $out/vpsadminos/.version-suffix
      echo -n ${config.system.vpsadminos.revision} > $out/vpsadminos/.git-revision
      echo ${config.system.vpsadminos.versionSuffix} | sed -e s/pre// > $out/vpsadminos/svn-revision
    '';

in

{
  options = {
    os.channel-registration.enable = mkOption {
      type = types.bool;
      default = true;
    };
  };

  config = mkIf config.os.channel-registration.enable {
    # Provide the vpsAdminOS/Nixpkgs sources. This is required
    # for os-install.
    runit.services.channel-registration = {
      run = ''
        ensureServiceStarted eudev-trigger
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
  };
}
