{
  config,
  pkgs,
  lib,
  modulesPath,
  ...
}:
let
  configClone = pkgs.writeText "configuration.nix" ''
    { config, pkgs, ... }:
    {
      imports = [
        ./vpsadminos.nix
      ];

      environment.systemPackages = with pkgs; [
        vim
      ];

      services.openssh = {
        enable = true;

        # Allow root login with password, needed for passwords set through vpsAdmin
        settings.PermitRootLogin = "yes";

        # Needed for public keys deployed through vpsAdmin, can be disabled if you
        # authorize your keys in configuration
        authorizedKeysInHomedir = true;
      };

      # Add your public keys
      #users.users.root.openssh.authorizedKeys.keys =
      #  [ "..." ];

      systemd.settings.Manager = {
        DefaultTimeoutStartSec = "900s";
      };

      time.timeZone = "Europe/Amsterdam";

      system.stateVersion = "${lib.trivial.release}";
    }
  '';

in
{
  imports = [
    "${modulesPath}/installer/cd-dvd/channel.nix"
    "${modulesPath}/virtualisation/container-config.nix"
    ./vpsadminos.nix
  ];

  environment.systemPackages = with pkgs; [ vim ];
  time.timeZone = "Europe/Amsterdam";
  system.stateVersion = lib.trivial.release;

  services.openssh = {
    enable = lib.mkDefault true;
    settings.PermitRootLogin = lib.mkDefault "yes";
    authorizedKeysInHomedir = true;
  };

  systemd.settings.Manager = {
    DefaultTimeoutStartSec = "900s";
  };

  boot.postBootCommands = ''
    # After booting, register the contents of the Nix store in the Nix database.
    if [ -f /nix/nix-path-registration ]; then
      ${config.nix.package.out}/bin/nix-store --load-db < /nix/nix-path-registration &&
      rm /nix/nix-path-registration
    fi

    # nixos-rebuild also requires a "system" profile
    ${config.nix.package.out}/bin/nix-env -p /nix/var/nix/profiles/system --set /run/current-system

    # Add profiles to gcroots
    ln -sf /nix/var/nix/profiles /nix/var/nix/gcroots/profiles

    # Copy configuration required to reproduce this build
    if ! [ -e /etc/nixos/configuration.nix ]; then
      cp ${configClone} /etc/nixos/configuration.nix
      chmod +w /etc/nixos/configuration.nix
    fi

    if ! [ -e /etc/nixos/vpsadminos.nix ]; then
      cp ${./vpsadminos.nix} /etc/nixos/vpsadminos.nix
      chmod +w /etc/nixos/vpsadminos.nix
    fi
  '';

  system.build.tarball = import "${pkgs.path}/nixos/lib/make-system-tarball.nix" {
    inherit (pkgs) stdenv closureInfo pixz;
    compressCommand = "gzip";
    compressionExtension = ".gz";
    extraInputs = [ pkgs.gzip ];

    contents = [ ];
    storeContents = [
      {
        object = config.system.build.toplevel;
        symlink = "/run/current-system";
      }
    ];
    extraCommands = pkgs.writeScript "extra-commands.sh" ''
      mkdir -p boot dev etc proc sbin sys
      ln -s ${config.system.build.toplevel}/init sbin/init
    '';
  };
}
