{ pkgs, config, lib, ... }:
with lib;
let
  cfg = config.boot.qemu;

  qemu = pkgs.qemu_kvm.override {
    hostCpuOnly = true;
    nixosTestRunner = true;
  };

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

  network =
    { config, ... }:
    {
      options = {
        type = mkOption {
          type = types.enum [ "user" "socket" "bridge" ];
          description = lib.mdDoc ''
            Network type

            `user` can create a network even when qemu is run as an unprivileged
            user and without any additional configuration. However, there are
            several limitations, see

              https://wiki.qemu.org/Documentation/Networking#User_Networking_(SLIRP)

            `socket` can be used to interconnect multiple qemu machines without requiring
            any other configuration on the host, see

              https://wiki.qemu.org/Documentation/Networking#Socket

            `bridge` can add the guest into an existing bridge interface,
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

        socket = {
          mcast = {
            address = mkOption {
              type = types.str;
              default = "230.0.0.1";
              description = ''
                Multicast address
              '';
            };

            port = mkOption {
              type = types.oneOf [
                (types.enum [ "net1" "net2" "net3" "net4" ])
                types.ints.positive
              ];
              default = "net1";
              description = ''
                Multicast port

                Enum values are automatically assigned by `osvm`, each enum value
                is assigned a unique port number, which makes it possible to create
                four separate networks.
              '';
            };
          };
        };

        bridge = {
          link = mkOption {
            type = types.str;
            description = ''
              Name of the bridge interface on the host to use
            '';
          };

          mac = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "MAC address, generated randomly by default";
          };
        };
      };
    };

  mkSharedFileSystems = listToAttrs (map (fs: nameValuePair fs.guestPath {
    device = fs.handle;
    fsType = "virtiofs";
  }) cfg.sharedFileSystems);

  machineConfig = {
    qemu = toString qemu;
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
    kernelParams = config.boot.kernelParams ++ [ "panic=-1" ];
    networks = map (net: {
      type = net.type;
      opts = {
        user = { inherit (net.user) network host dns hostForward; };
        socket = { mcast = { inherit (net.socket.mcast) address port; }; };
        bridge = { inherit (net.bridge) link mac; };
      }.${net.type} or {};
    }) cfg.networks;
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

      networks = mkOption {
        type = types.listOf (types.submodule network);
        default = [
          { type = "user"; }
        ];
        description = ''
          Network devices
        '';
      };

      extraQemuOptions = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Extra command-line arguments passed to qemu";
      };

      stateDir = mkOption {
        type = types.str;
        defaultText = ''~/.osvm-qemu/''${config.networking.hostName}'';
        description = ''
          Directory where qemu-related files are stored, e.g. socket files,
          disk files, etc.
        '';
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      boot.qemu.stateDir = mkDefault "~/.osvm-qemu/${config.networking.hostName}";

      boot.kernelParams = [ "console=ttyS0" ];

      system.build.runvm = pkgs.writeScript "vpsadminos-qemu-runner" ''
        #!${pkgs.stdenv.shell}
        exec ${pkgs.osvm}/bin/osvm script ${osvmScript}
      '';

      system.build.runvmScript =
        let
          diskPath = disk:
            if hasPrefix "/" disk.device then
              disk.device
            else "${cfg.stateDir}/${disk.device}";

          diskParams = (flatten (imap0 (i: disk: [
            "-drive id=disk${toString i},file=${diskPath disk},if=none,format=raw"
            "-device ide-hd,drive=disk${toString i},bus=ahci.${toString i}"
          ]) cfg.disks));
        in pkgs.writeScript "vpsadminos-qemu-runner.sh" ''
          #!${pkgs.stdenv.shell}
          mkdir -p "${cfg.stateDir}"

          ${concatStringsSep "\n" (map (disk: ''
            devicePath="${disk.device}"
            [[ "$devicePath" == /* ]] || devicePath="${cfg.stateDir}/$devicePath"
            [ ! -f "$devicePath" ] && truncate -s${toString disk.size} "$devicePath"
          '') (filter (disk: disk.type == "file" && disk.create) cfg.disks))}

          exec ${qemu}/bin/qemu-kvm -name vpsadminos -m ${toString cfg.memory} \
            -cpu host \
            -smp cpus=${toString cfg.cpus},cores=${toString cfg.cpu.cores},threads=${toString cfg.cpu.threads},sockets=${toString cfg.cpu.sockets} \
            -no-reboot \
            -device ahci,id=ahci \
            -device virtio-net,netdev=net0 \
            -netdev user,id=net0,net=10.0.2.0/24,host=10.0.2.2,dns=10.0.2.3,hostfwd=tcp::2222-:22 \
            -drive index=0,id=drive1,file=${config.system.build.squashfs},readonly=on,media=cdrom,format=raw,if=virtio \
            -kernel ${config.system.build.kernel}/bzImage \
            -initrd ${config.system.build.initialRamdisk}/initrd \
            -append "init=${config.system.build.toplevel}/init ${toString config.boot.kernelParams} panic=-1" \
            -nographic \
            ${lib.concatStringsSep " \\\n  " diskParams} \
            ${lib.concatStringsSep " \\\n  " cfg.extraQemuOptions}
        '';

      fileSystems = mkSharedFileSystems;
    })

    (mkIf (cfg.enable && cfg.sharedFileSystems != []) {
      system.activationScripts.qemu-sharedFileSystems =
        "mkdir -p " + concatMapStringsSep " " (fs: "\"${fs.guestPath}\"") cfg.sharedFileSystems;
    })
  ];
}
