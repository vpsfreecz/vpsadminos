{ config, pkgs, lib, ...}: {

  services.resolved = lib.mkDefault {
    enable = true;
    fallbackDns = [
      "37.205.9.100"
      "37.205.10.88"
      "1.1.1.1" ];
  };

  systemd.services.systemd-sysctl.enable = false;
  systemd.sockets."systemd-journald-audit".enable = false;
  systemd.mounts = [ {where = "/sys/kernel/debug"; enable = false;} ];

  boot.isContainer = true;
  boot.specialFileSystems."/run/keys".fsType = lib.mkForce "tmpfs";

  boot.postBootCommands =
    ''
      # After booting, register the contents of the Nix store in the Nix database.
      if [ -f /nix-path-registration ]; then
        ${config.nix.package.out}/bin/nix-store --load-db < /nix-path-registration &&
        rm /nix-path-registration
      fi

      # nixos-rebuild also requires a "system" profile
      ${config.nix.package.out}/bin/nix-env -p /nix/var/nix/profiles/system --set /run/current-system
    '';

  system.build.tarball = import <nixpkgs/nixos/lib/make-system-tarball.nix> {
    inherit (pkgs) stdenv perl pixz pathsFromGraph;
    compressCommand = "gzip";
    compressionExtension = ".gz";
    extraInputs = [ pkgs.gzip ];

    contents = [];
    storeContents = [
      { object = config.system.build.toplevel + "/init";
        symlink = "/sbin/init";
      }
      { object = config.system.build.toplevel;
        symlink = "/run/current-system";
      }
    ];
    extraCommands = "mkdir -p proc sys dev etc";
  };

  system.activationScripts.installInitScript = ''
    ln -fs $systemConfig/init /sbin/init
  '';
}
