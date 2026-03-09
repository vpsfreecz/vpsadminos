{
  config,
  pkgs,
  lib,
  modulesPath,
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
  flakeClone = import ../template-flake.nix {
    inherit
      homeManagerNode
      impermanenceNode
      impermanenceNixpkgsNode
      lib
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
      impermanenceNode
      impermanenceNixpkgsNode
      lib
      nixpkgsNode
      pkgs
      stableNixpkgsNode
      unstableNixpkgsNode
      vpsadminosGithubRev
      ;
  };
  copyFlakeLockCommands = lib.optionalString (flakeLockClone != null) ''
    if ! [ -e /etc/nixos/flake.lock ]; then
      cp ${flakeLockClone} /etc/nixos/flake.lock
      chmod +w /etc/nixos/flake.lock
    fi
  '';

  configClone = pkgs.writeText "configuration.nix" ''
    { inputs, lib, pkgs, ... }:
    {
      nix.settings.experimental-features = [
        "nix-command"
        "flakes"
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
  imports = [ ./base.nix ];

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

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
    mkdir -p /etc/nixos

    if ! [ -e /etc/nixos/flake.nix ]; then
      cp ${flakeClone} /etc/nixos/flake.nix
      chmod +w /etc/nixos/flake.nix
    fi

    ${copyFlakeLockCommands}

    if ! [ -e /etc/nixos/configuration.nix ]; then
      cp ${configClone} /etc/nixos/configuration.nix
      chmod +w /etc/nixos/configuration.nix
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
