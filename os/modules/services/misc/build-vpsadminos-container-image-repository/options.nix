{ config, pkgs, lib, ... }:
with lib;
let
  varDir = "/var/lib/vpsadminos-container-image-repository";

  repoModule =
    { config, name, ... }:
    {
      options = {
        enable = mkEnableOption ''
          Enable the systemd service for this repository
        '';

        osModules = mkOption {
          type = types.listOf types.anything;
          default = [];
          description = ''
            Modules included in the vpsAdminOS virtual machine

            This list should include at least a module which configures option
            <option>services.osctl.image-repository.&lt;name&gt;</option>
            from vpsAdminOS for the repository of the same name.
          '';
        };

        osVm = {
          memory = mkOption {
            internal = true;
            default = 4096;
            type = types.addCheck types.int (n: n > 256);
            description = "QEMU RAM in megabytes";
          };

          cpus = mkOption {
            internal = true;
            default = 1;
            type = types.addCheck types.int (n: n >= 1);
            description = "Number of available CPUs";
          };

          cpu.cores = mkOption {
            internal = true;
            default = 1;
            type = types.addCheck types.int (n: n >= 1);
            description = "Number of available CPU cores";
          };

          cpu.threads = mkOption {
            internal = true;
            default = 1;
            type = types.addCheck types.int (n: n >= 1);
            description = "Number of available threads";
          };

          cpu.sockets = mkOption {
            internal = true;
            default = 1;
            type = types.addCheck types.int (n: n >= 1);
            description = "Number of available CPU sockets";
          };

          disks = mkOption {
            type = types.listOf (types.submodule qemuDisk);
            example = [
              { device = "sda.img"; type = "file"; size = "8G"; create = true; }
            ];
            description = "Disks available within the VM";
          };
        };

        buildScripts = mkOption {
          type = types.path;
          default = ../../../../../image-scripts;
          description = ''
            Build scripts for use with osctl-image
          '';
        };

        cacheDirectory = mkOption {
          type = types.path;
          default = "${varDir}/${name}/cache";
          description = ''
            Directory where built images are stored
          '';
        };

        logDirectory = mkOption {
          type = types.path;
          default = "${varDir}/${name}/log";
          description = ''
            Directory where build log files are stored
          '';
        };

        repositoryDirectory = mkOption {
          type = types.path;
          default = "${varDir}/${name}/repository";
          description = ''
            Directory where the resulting container image repository is stored
          '';
        };

        postRunCommands = mkOption {
          type = types.lines;
          default = "";
          description = ''
            Bash commands run after the build VM has exited. It is also run
            when the built has failed.
          '';
        };
      };
    };

  qemuDisk = {
    options = {
      device = mkOption {
        type = types.str;
        description = "Path to the disk device";
      };

      type = mkOption {
        type = types.enum [ "file" "blockdev" ];
        description = "Device type";
      };

      size = mkOption {
        type = types.str;
        default = "";
        description = "Device size";
      };

      create = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Create the device if it does not exist. Applicable only
          for file-backed devices.
        '';
      };
    };
  };
in {
  options = {
    services.build-vpsadminos-container-image-repository = mkOption {
      type = types.attrsOf (types.submodule repoModule);
      description = ''
        This module provides interface for building vpsAdminOS container image
        repositories in a virtual machine running vpsAdminOS.
      '';
    };
  };

  config = {
    services.build-vpsadminos-container-image-repository.vpsadminos = {
      osModules = [
        ({ config, ... }:
        {
          imports = [
            ../../../../configs/image-repository.nix
          ];

          boot.kernelParams = [ "root=/dev/vda" ];
          boot.initrd.kernelModules = [
            "virtio" "virtio_pci" "virtio_net" "virtio_rng" "virtio_blk" "virtio_console"
          ];

          networking.hostName = mkDefault "vpsadminos";
          networking.static.enable = mkDefault true;
          networking.lxcbr.enable = mkDefault true;
          networking.nameservers = mkDefault [ "10.0.2.3" ];

          osctl.test-shell.enable = true;
          osctld.settings = {
            trash_bin.prune_interval = 1*60;
          };

          tty.autologin.enable = mkDefault true;
          services.haveged.enable = mkDefault true;
          os.channel-registration.enable = mkDefault false;

          nix.nixPath = [
            "nixpkgs=${<nixpkgs>}"
          ];

          boot.zfs.pools.tank = {
            layout = [
              { devices = [ "sda" ]; }
            ];
            importAttempts = lib.mkDefault 3;
            doCreate = true;
            install = true;
            datasets = {
              "image-repository/build-dataset" = {};
            };
          };

          services.osctl.image-repository.vpsadminos = {
            path = "/mnt/repoDir";
            cacheDir = "/mnt/cacheDir";
            buildScriptDir = "/mnt/buildScripts";
            buildDataset = "tank/image-repository/build-dataset";
            logDir = "/mnt/logDir";
          };
        })
      ];
    };
  };
}
