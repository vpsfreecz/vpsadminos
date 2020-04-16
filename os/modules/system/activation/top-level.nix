{ pkgs, config, lib, ... }:
with lib;
{
  options = {
    system.build = mkOption {
      internal = true;
      default = {};
      description = "Attribute set of derivations used to setup the system.";
    };
    system.extraDependencies = mkOption {
      type = types.listOf types.package;
      default = [];
      description = ''
        A list of packages that should be included in the system
        closure but not otherwise made available to users. This is
        primarily used by the installation tests.
      '';
    };
    system.storeOverlaySize = mkOption {
      default = "2G";
      type = types.str;
      description = ''
        Size of the tmpfs filesystems used as an overlay for /nix/store.
        See option size in man tmpfs(5) for possible values.
      '';
    };
    boot.isContainer = mkOption {
      type = types.bool;
      default = false;
    };
    boot.predefinedFailAction = mkOption {
      type = types.enum ["" "n" "i" "r" "*" ];
      default = "";
      description = ''
        Action to take automatically if stage-1 fails.

        n - create new pool (may also erase disks and run partitioning if configured)
        i - interactive shell
        r - reboot
        * - ignore

        Useful for unattended installations and testing.
      '';
    };
    system.boot.loader.id = mkOption {
      internal = true;
      default = "";
      description = ''
        Id string of the used bootloader.
      '';
    };
    system.boot.loader.kernelFile = mkOption {
      internal = true;
      default = pkgs.stdenv.platform.kernelTarget;
      type = types.str;
      description = ''
        Name of the kernel file to be passed to the bootloader.
      '';
    };
    system.boot.loader.initrdFile = mkOption {
      internal = true;
      default = "initrd";
      type = types.str;
      description = ''
        Name of the initrd file to be passed to the bootloader.
      '';
    };
    vpsadminos.nix = mkOption {
      type = types.bool;
      default = true;
      description = "enable nix-daemon and a writeable store";
    };
  };

####################
#                  #
#  Implementation  #
#                  #
####################

  config =
    let
      cfg = config.system;
    in {
      environment.systemPackages = lib.optional config.vpsadminos.nix pkgs.nix;
      nixpkgs.config = {
        packageOverrides = self: rec {
        };
      };

      system.build.earlyMountScript = pkgs.writeScript "dummy" ''
      '';

      system.build.dist = pkgs.runCommand "vpsadminos-dist" {} ''
        mkdir $out
        cp ${config.system.build.squashfs} $out/root.squashfs
        cp ${config.system.build.kernel}/*zImage $out/kernel
        cp ${config.system.build.initialRamdisk}/initrd $out/initrd
        echo "systemConfig=${config.system.build.toplevel} ${builtins.unsafeDiscardStringContext (toString config.boot.kernelParams)}" > $out/command-line
      '';

      system.build.toplevel =
        let
          name = let hn = config.networking.hostName;
                     nn = if (hn != "") then hn else "unnamed";
                 in "vpsadminos-system-${nn}-${config.system.osLabel}";

          kernelPath = "${config.boot.kernelPackages.kernel}/" +
            "${config.system.boot.loader.kernelFile}";

          initrdPath = "${config.system.build.initialRamdisk}/" +
            "${config.system.boot.loader.initrdFile}";

          serviceList = pkgs.writeText "services.json" (builtins.toJSON {
            defaultRunlevel = config.runit.defaultRunlevel;

            services = lib.mapAttrs (k: v: {
              inherit (v) runlevels onChange reloadMethod;
            }) config.runit.services;
          });

          baseSystem = pkgs.runCommand name {
            activationScript = config.system.activationScripts.script;
            ruby = pkgs.ruby;
            etc = config.system.build.etc;
            installBootLoader = config.system.build.installBootLoader or "none";
            inherit (config.boot) kernelParams;
          } ''
            mkdir $out
            cp ${config.system.build.bootStage2} $out/init
            substituteInPlace $out/init --subst-var-by systemConfig $out
            ln -s ${config.system.path} $out/sw
            ln -s ${kernelPath} $out/kernel
            ln -s ${initrdPath} $out/initrd
            ln -s ${config.system.modulesTree} $out/kernel-modules
            echo -n "${config.system.osLabel}" > $out/os-version
            echo -n "$kernelParams" > $out/kernel-params
            ln -s ${serviceList} $out/services
            echo "$activationScript" > $out/activate
            substituteInPlace $out/activate --subst-var out
            chmod u+x $out/activate
            unset activationScript

            mkdir $out/bin
            substituteAll ${./switch-to-configuration.rb} $out/bin/switch-to-configuration
            chmod +x $out/bin/switch-to-configuration

            echo -n "${toString config.system.extraDependencies}" > $out/extra-dependencies
          '';

          failedAssertions = map (x: x.message) (filter (x: !x.assertion) config.assertions);

          showWarnings = res: fold (w: x: builtins.trace "[1;31mwarning: ${w}[0m" x) res config.warnings;

          baseSystemAssertWarn = if failedAssertions != []
            then throw "\nFailed assertions:\n${concatStringsSep "\n" (map (x: "- ${x}") failedAssertions)}"
            else showWarnings baseSystem;

          system = baseSystemAssertWarn;

        in system;

      system.build.squashfs = pkgs.callPackage ../../../lib/make-squashfs.nix {
        storeContents = [ config.system.build.toplevel ];
        secretsDir = config.system.secretsDir;
      };

      system.build.kernelParams = config.boot.kernelParams;

      # Needed for nixops send-keys
      users.groups.keys.gid = config.ids.gids.keys;
    };
}
