{
  config,
  pkgs,
  lib,
  modulesPath,
  impermanence,
  impermanenceNode,
  impermanenceNixpkgsNode,
  homeManagerNode,
  nixpkgsNode,
  stableNixpkgsNode,
  unstableNixpkgsNode,
  vpsadminosGithubRev ? null,
  ...
}:
let
  impermanenceModule = impermanence;
  flakeClone = import ../template-flake.nix {
    inherit
      homeManagerNode
      lib
      impermanenceNode
      impermanenceNixpkgsNode
      nixpkgsNode
      pkgs
      stableNixpkgsNode
      unstableNixpkgsNode
      ;
    containerModule = "containerUnstable";
  };
  flakeLockClone = import ../template-flake-lock.nix {
    inherit
      homeManagerNode
      lib
      impermanenceNode
      impermanenceNixpkgsNode
      nixpkgsNode
      pkgs
      stableNixpkgsNode
      unstableNixpkgsNode
      vpsadminosGithubRev
      ;
  };
  copyFlakeLockCommands = lib.optionalString (flakeLockClone != null) ''
    if ! [ -e /persistent/etc/nixos/flake.lock ]; then
      cp ${flakeLockClone} /persistent/etc/nixos/flake.lock
      chmod +w /persistent/etc/nixos/flake.lock
    fi
  '';

  configClone = pkgs.writeText "configuration.nix" ''
    { inputs, lib, pkgs, ... }:
    {
      imports = [
        inputs.impermanence.nixosModules.impermanence
      ];

      nix.settings.experimental-features = [
        "nix-command"
        "flakes"
      ];

      environment.systemPackages = with pkgs; [
        vim
      ];

      services.openssh.enable = true;
      services.openssh.settings.PermitRootLogin = "yes";
      #users.extraUsers.root.openssh.authorizedKeys.keys =
      #  [ "..." ];

      systemd.settings.Manager = {
        DefaultTimeoutStartSec = "900s";
      };

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

in
{
  imports = [
    ./base.nix
    "${impermanenceModule}/nixos.nix"
  ];

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

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

    if ! [ -e /persistent/etc/nixos/flake.nix ]; then
      cp ${flakeClone} /persistent/etc/nixos/flake.nix
      chmod +w /persistent/etc/nixos/flake.nix
    fi

    ${copyFlakeLockCommands}

    if ! [ -e /persistent/etc/nixos/configuration.nix ]; then
      cp ${configClone} /persistent/etc/nixos/configuration.nix
      chmod +w /persistent/etc/nixos/configuration.nix
    fi
  '';

  system.build.impermanenceTarball = import "${pkgs.path}/nixos/lib/make-system-tarball.nix" {
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
      # Needed for first container start; impermanence support in osctld relies on
      # /nix/var/nix/profiles/system
      mkdir -p nix/var/nix/profiles
      ln -s ${config.system.build.toplevel} nix/var/nix/profiles/system
    '';
  };
}
