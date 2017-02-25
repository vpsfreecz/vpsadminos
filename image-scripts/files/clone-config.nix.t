{ config, lib, pkgs, modules, ... }:

with lib;

let
  # How about just using some meta bash to populate this
  configClone = pkgs.writeText "configuration.nix"
    ''
    {{{METANIX}}}
    '';
in
{
  options = {
    installer.cloneConfig = mkOption {
      default = true;
      description = ''
        Try to clone the installation-device configuration by re-using it's
        profile from the list of imported modules.
      '';
    };
  };

  config = {
    boot.postBootCommands =
      ''
        # Provide a mount point for nixos-install.
        mkdir -p /mnt

        ${optionalString config.installer.cloneConfig ''
          # Provide a configuration for the CD/DVD itself, to allow users
          # to run nixos-rebuild to change the configuration of the
          # running system on the CD/DVD.
          if ! [ -e /etc/nixos/configuration.nix ]; then
            cp ${configClone} /etc/nixos/configuration.nix
            chmod +w /etc/nixos/configuration.nix
          fi
       ''}
      '';
  };
}
