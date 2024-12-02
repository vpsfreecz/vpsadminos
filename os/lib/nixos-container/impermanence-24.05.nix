{ config, pkgs, lib, ... }:
let
  # Use custom nixpkgs instance to fetch impermanence module, as otherwise
  # having it in imports results in infinite recursion
  impermanence = (import <nixpkgs> {}).fetchFromGitHub {
    owner = "nix-community";
    repo = "impermanence";
    rev = "e337457502571b23e449bf42153d7faa10c0a562";
    sha256 = "sha256-C2sGRJl1EmBq0nO98TNd4cbUy20ABSgnHWXLIJQWRFA=";
  };

  configClone = pkgs.writeText "configuration.nix" ''
    { config, pkgs, ... }:
    {
      imports = [
        ./vpsadminos.nix

        # Copy of the impermanence module is stored in /etc/nixos/impermanence.
        # See https://github.com/nix-community/impermanence for the latest version.
        ./impermanence/nixos.nix
      ];

      environment.systemPackages = with pkgs; [
        vim
      ];

      services.openssh.enable = true;
      services.openssh.settings.PermitRootLogin = "yes";
      #users.extraUsers.root.openssh.authorizedKeys.keys =
      #  [ "..." ];

      systemd.extraConfig = '''
        DefaultTimeoutStartSec=900s
      ''';

      time.timeZone = "Europe/Amsterdam";

      environment.persistence."/persistent" = {
        hideMounts = true;
        directories = [
          "/etc/nixos"
          "/var/log"
          "/var/lib/nixos"
        ];
        files = [
          "/etc/machine-id"
        ];
      };

      system.stateVersion = "${lib.trivial.release}";
    }
  '';

in {
  imports = [
    <nixpkgs/nixos/modules/installer/cd-dvd/channel.nix>
    <nixpkgs/nixos/modules/virtualisation/container-config.nix>
    ./vpsadminos.nix
    "${impermanence}/nixos.nix"
  ];

  environment.systemPackages = with pkgs; [ vim ];
  time.timeZone = "Europe/Amsterdam";
  system.stateVersion = lib.trivial.release;

  services.openssh.enable = lib.mkDefault true;
  services.openssh.settings.PermitRootLogin = lib.mkDefault "yes";

  systemd.extraConfig = ''
    DefaultTimeoutStartSec=900s
  '';

  environment.persistence."/persistent" = {
    hideMounts = true;
    directories = [
      "/etc/nixos"
      "/var/log"
      "/var/lib/nixos"
    ];
    files = [
      "/etc/machine-id"
    ];
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
    mkdir -p /persistent/etc/nixos

    if ! [ -e /persistent/etc/nixos/configuration.nix ]; then
      cp ${configClone} /persistent/etc/nixos/configuration.nix
      chmod +w /persistent/etc/nixos/configuration.nix
    fi

    if ! [ -e /persistent/etc/nixos/vpsadminos.nix ]; then
      cp ${./vpsadminos.nix} /persistent/etc/nixos/vpsadminos.nix
      chmod +w /etc/nixos/vpsadminos.nix
    fi

    if ! [ -d /persistent/etc/nixos/impermanence ]; then
      cp -r ${impermanence} /persistent/etc/nixos/impermanence
      find /persistent/etc/nixos/impermanence -type f -exec chmod u+w {} \;
    fi
  '';

  system.build.impermanenceTarball = import <nixpkgs/nixos/lib/make-system-tarball.nix> {
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
      # Needed for first container start; impermanence support in osctld relies on
      # /nix/var/nix/profiles/system
      mkdir -p nix/var/nix/profiles
      ln -s ${config.system.build.toplevel} nix/var/nix/profiles/system
    '';
  };
}
