{ pkgs, config, lib, ... }:
with lib;
let
  cfg = config.boot.qemu;

  qemuDisk =
    { config, ... }:
    {
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

  sharedFileSystem =
    { config, ... }:
    {
      options = {
        handle = mkOption {
          type = types.str;
          description = "Handle for mounting";
        };

        hostPath = mkOption {
          type = types.path;
          description = "Source directory on the host";
        };

        guestPath = mkOption {
          type = types.path;
          description = "Target mountpoint in the guest";
        };
      };
    };

  mkSharedFileSystems = listToAttrs (map (fs: nameValuePair fs.guestPath {
    device = fs.handle;
    fsType = "virtiofs";
  }) cfg.sharedFileSystems);

  machineConfig = {
    qemu = toString pkgs.qemu_kvm;
    extraQemuOptions = cfg.extraQemuOptions;
    virtiofsd = toString pkgs.virtiofsd;
    memory = cfg.memory;
    cpus = cfg.cpus;
    cpu = cfg.cpu;
    disks = cfg.disks;
    sharedFileSystems = listToAttrs (map (fs: nameValuePair fs.handle fs.hostPath) cfg.sharedFileSystems);
    squashfs = config.system.build.squashfs;
    kernel = "${config.system.build.kernel}/bzImage";
    initrd = "${config.system.build.initialRamdisk}/initrd";
    toplevel = config.system.build.toplevel;
    kernelParams = config.boot.kernelParams ++ [ "quiet" "panic=-1" ];
  };

  machineConfigFile = pkgs.writeText "machine-config.json" (builtins.toJSON machineConfig);

  osvmScript = pkgs.writeText "osvm-script.rb" ''
    guest_dir = File.join(".osvm-qemu", "${config.networking.hostName}")

    machine = OsVm::Machine.new(
      "${config.networking.hostName}",
      OsVm::MachineConfig.load_file("${machineConfigFile}"),
      guest_dir,
      guest_dir,
      interactive_console: true,
    )
    machine.start
    machine.join(timeout: nil)
    machine.finalize
    machine.cleanup
  '';
in {
  options = {
    boot.qemu = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          QEMU runner
        '';
      };

      memory = mkOption {
        internal = true;
        default = 8192;
        type = types.addCheck types.int (n: n > 256);
        description = "QEMU RAM in megabytes";
      };

      cpus = mkOption {
        internal = true;
        default = 4;
        type = types.addCheck types.int (n: n >= 1);
        description = "Number of available CPUs";
      };

      cpu.cores = mkOption {
        internal = true;
        default = 4;
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
        default = [
          { device = "sda.img"; type = "file"; size = "8G"; create = true; }
        ];
        description = "Disks available within the VM";
      };

      sharedFileSystems = mkOption {
        type = types.listOf (types.submodule sharedFileSystem);
        default = [];
        description = "Filesystems shared between the host and the VM (the guest)";
      };

      extraQemuOptions = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Extra command-line arguments passed to qemu";
      };
    };
  };

  config = mkIf cfg.enable {
    boot.kernelParams = [ "console=ttyS0" ];

    system.build.runvm = pkgs.writeScript "vpsadminos-qemu-runner" ''
      #!${pkgs.stdenv.shell}
      exec ${pkgs.osvm}/bin/osvm script ${osvmScript}
    '';

    boot.postBootCommands = "mkdir -p " + concatMapStringsSep " " (fs: "\"${fs.guestPath}\"") cfg.sharedFileSystems;

    fileSystems = mkSharedFileSystems;
  };
}
