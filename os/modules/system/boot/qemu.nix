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
          type = types.str;
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
    network = {
      mode = cfg.network.mode;
      opts = {
        user = { inherit (cfg.network.user) network host dns hostForward; };
        bridge = { link = cfg.network.bridge.link; };
      }.${cfg.network.mode} or {};
    };
  };

  machineConfigFile = pkgs.writeText "machine-config.json" (builtins.toJSON machineConfig);

  osvmScript = pkgs.writeText "osvm-script.rb" ''
    guest_dir = File.expand_path("${cfg.stateDir}")

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

      network = {
        mode = mkOption {
          type = types.enum [ "user" "bridge" ];
          default = "user";
          description = lib.mdDoc ''
            Network mode

            Mode `user` can create a network even when qemu is run as an unprivileged
            user and without any additional configuration. However, there are
            several limitations, see

              https://wiki.qemu.org/Documentation/Networking#User_Networking_(SLIRP)

            Mode `bridge` can add the guest into an existing bridge interface,
            making it a part of your network, etc. It requires the bridge to be
            configured and the guest must be run as root.
          '';
        };

        user = {
          network = mkOption {
            type = types.str;
            default = "10.0.2.0/24";
          };

          host = mkOption {
            type = types.str;
            default = "10.0.2.2";
          };

          dns = mkOption {
            type = types.str;
            default = "10.0.2.3";
          };

          hostForward = mkOption {
            type = types.nullOr types.str;
            default = "tcp::2222-:22";
          };
        };

        bridge.link = mkOption {
          type = types.str;
          description = ''
            Name of the bridge interface on the host to use
          '';
        };
      };

      extraQemuOptions = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Extra command-line arguments passed to qemu";
      };

      stateDir = mkOption {
        type = types.str;
        defaultText = ''~/.local/share/vpsadminos/.osvm-qemu/''${config.networking.hostName}'';
        description = ''
          Directory where qemu-related files are stored, e.g. socket files,
          disk files, etc.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    boot.qemu.stateDir = mkDefault "~/.local/share/vpsadminos/osvm-qemu/${config.networking.hostName}";

    boot.kernelParams = [ "console=ttyS0" ];

    system.build.runvm = pkgs.writeScript "vpsadminos-qemu-runner" ''
      #!${pkgs.stdenv.shell}
      exec ${pkgs.osvm}/bin/osvm script ${osvmScript}
    '';

    system.activationScripts.qemu-sharedFileSystems =
      "mkdir -p " + concatMapStringsSep " " (fs: "\"${fs.guestPath}\"") cfg.sharedFileSystems;

    fileSystems = mkSharedFileSystems;
  };
}
