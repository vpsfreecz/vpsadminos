#
# vpsfree nixos config (openvz)
#

{ config, pkgs, ... }:
with pkgs.lib;
let pkgsSnapshot = (import (pkgs.fetchFromGitHub {
       owner = "NixOS";
       repo = "nixpkgs";
       rev = "300fa462b31ad2106d37fcdb4b504ec60dfd62aa";
       sha256 = "1cbjmi34ll5xa2nafz0jlsciivj62mq78qr3zl4skgdk6scl328s";
   }) {});
in
{
    imports =
      [
        <nixpkgs/nixos/modules/profiles/minimal.nix>
        <nixpkgs/nixos/modules/virtualisation/container-config.nix>
        <nixpkgs/nixos/modules/installer/cd-dvd/channel.nix>
        ./gen/clone-config.nix # optionally include itself
      ];

    services.openssh.enable = true;
    services.openssh.permitRootLogin = "yes";

    networking = {
      hostName = "nixos";
      useHostResolvConf = true;
    };

    fileSystems = [ ];

    system.build.tarball = import <nixpkgs/nixos/lib/make-system-tarball.nix> {
      inherit (pkgs) stdenv perl xz pathsFromGraph;

      contents = [];
      storeContents = [
        { object = config.system.build.toplevel + "/init";
          symlink = "/init";
        }
        { object = config.system.build.toplevel + "/init";
          symlink = "/bin/init";
        }
        { object = config.system.build.toplevel;
          symlink = "/run/current-system";
        }
        # this is needed as openvz uses /bin/sh for running scripts before container starts
        { object = config.environment.binsh;
          symlink = "/bin/sh";
        }
      ];
      extraCommands = "mkdir -p etc proc sys dev/shm dev/pts run";
    };

    boot.isContainer = true;
    boot.loader.grub.enable = false;
    boot.postBootCommands =
      ''
        # After booting, register the contents of the Nix store in the Nix database.
        if [ -f /nix-path-registration ]; then
          ${config.nix.package.out}/bin/nix-store --load-db < /nix-path-registration &&
          rm /nix-path-registration
        fi

        # nixos-rebuild also requires a "system" profile
        ${config.nix.package.out}/bin/nix-env -p /nix/var/nix/profiles/system --set /run/current-system

        # we may supply this from host, default /etc/resolv.conf copying in stage-2 works only when /run is mounted from host
        if [ -e /resolv.conf ]; then
          cat /resolv.conf | resolvconf -m 1000 -a host
        fi
      '';

    boot.specialFileSystems."/run/keys".fsType = mkForce "tmpfs";

    # need to remove capabilities added by default by nixos/modules/tasks/network-interfaces.nix
    security.wrappers = {
         ping.source = "${pkgs.iputils.out}/bin/ping";
    };


    i18n = {
       defaultLocale = "en_US.UTF-8";
       # make sure not to list defaultLocale here again
       supportedLocales = ["en_US/ISO-8859-1"];
    };

    environment.systemPackages = [ pkgs.nvi ];

    # Install new init script(s), takes care of switching symlinks when e.g. nixos-rebuild switch(ing)
    system.activationScripts.installInitScript = ''
      ln -fs $systemConfig/init /init
      ln -fs $systemConfig/init /bin/init
    '';

    systemd.services."getty@".enable = false;
    systemd.services.systemd-sysctl.enable = false;

    systemd.services.networking-setup =
      { description = "Load network configuration provided by host";

        before = [ "network.target" ];
        wantedBy = [ "network.target" ];
        after = [ "network-pre.target" ];
        path = [ pkgs.iproute ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.bash}/bin/bash /ifcfg.start";
          ExecStop = "${pkgs.bash}/bin/bash /ifcfg.stop";
        };
      };

    nix.package = pkgsSnapshot.nix;
}
