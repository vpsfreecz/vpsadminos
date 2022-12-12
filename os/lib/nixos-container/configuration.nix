{ config, pkgs, lib, ... }:
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

      services.openssh.enable = true;
      services.openssh.permitRootLogin = "yes";
      #users.extraUsers.root.openssh.authorizedKeys.keys =
      #  [ "..." ];

      systemd.extraConfig = '''
        DefaultTimeoutStartSec=900s
      ''';

      time.timeZone = "Europe/Amsterdam";

      system.stateVersion = "${lib.trivial.release}";
    }
  '';

in {
  imports = [
    <nixpkgs/nixos/modules/installer/cd-dvd/channel.nix>
    <nixpkgs/nixos/modules/virtualisation/container-config.nix>
    ./vpsadminos.nix
  ];

  environment.systemPackages = with pkgs; [ vim ];
  time.timeZone = "Europe/Amsterdam";
  system.stateVersion = lib.trivial.release;

  services.openssh.enable = lib.mkDefault true;
  services.openssh.permitRootLogin = lib.mkDefault "yes";

  systemd.extraConfig = ''
    DefaultTimeoutStartSec=900s
  '';

  boot.postBootCommands = ''
    # After booting, register the contents of the Nix store in the Nix database.
    if [ -f /nix-path-registration ]; then
      ${config.nix.package.out}/bin/nix-store --load-db < /nix-path-registration &&
      rm /nix-path-registration
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

  system.build.tarball = import <nixpkgs/nixos/lib/make-system-tarball.nix> {
    inherit (pkgs) stdenv closureInfo pixz;
    compressCommand = "gzip";
    compressionExtension = ".gz";
    extraInputs = [ pkgs.gzip ];

    contents = [];
    storeContents = [
      { object = config.system.build.toplevel;
        symlink = "/run/current-system";
      }
    ];
    extraCommands = pkgs.writeScript "extra-commands.sh" ''
      mkdir -p boot dev etc proc sbin sys
      ln -s ${config.system.build.toplevel}/init sbin/init
    '';
  };
}
