{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    attrNames
    concatMapStringsSep
    concatStringsSep
    listToAttrs
    literalExpression
    optional
    optionalString
    mapAttrsToList
    mkIf
    mkMerge
    mkOption
    mkPackageOption
    nameValuePair
    types
    ;

  cfg = config.virtualisation.libvirtd;

  modules = [
    "qemu"
    "interface"
    "log"
    "lock"
    "network"
    "nodedev"
    "nwfilter"
    "proxy"
    "secret"
    "storage"
  ];

  qemuConfigFile = pkgs.writeText "qemu.conf" ''
    ${optionalString cfg.qemu.ovmf.enable ''
      nvram = [
        "/run/libvirt/nix-ovmf/AAVMF_CODE.fd:/run/libvirt/nix-ovmf/AAVMF_VARS.fd",
        "/run/libvirt/nix-ovmf/AAVMF_CODE.ms.fd:/run/libvirt/nix-ovmf/AAVMF_VARS.ms.fd",
        "/run/libvirt/nix-ovmf/OVMF_CODE.fd:/run/libvirt/nix-ovmf/OVMF_VARS.fd",
        "/run/libvirt/nix-ovmf/OVMF_CODE.ms.fd:/run/libvirt/nix-ovmf/OVMF_VARS.ms.fd"
      ]
    ''}
    ${optionalString (!cfg.qemu.runAsRoot) ''
      user = "qemu-libvirtd"
      group = "qemu-libvirtd"
    ''}
    ${cfg.qemu.verbatimConfig}
  '';

  dirName = "libvirt";

  subDirs = list: [ dirName ] ++ map (e: "${dirName}/${e}") list;

  vhostUserCollection = pkgs.buildEnv {
    name = "vhost-user";
    paths = cfg.qemu.vhostUserPackages;
    pathsToLink = [ "/share/qemu/vhost-user" ];
  };

  ovmfModule = types.submodule {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Allows libvirtd to take advantage of OVMF when creating new
          QEMU VMs with UEFI boot.
        '';
      };

      packages = mkOption {
        type = types.listOf types.package;
        default = [ pkgs.OVMF.fd ];
        defaultText = literalExpression "[ pkgs.OVMF.fd ]";
        example = literalExpression "[ pkgs.OVMFFull.fd pkgs.pkgsCross.aarch64-multiplatform.OVMF.fd ]";
        description = ''
          List of OVMF packages to use. Each listed package must contain files names FV/OVMF_CODE.fd and FV/OVMF_VARS.fd or FV/AAVMF_CODE.fd and FV/AAVMF_VARS.fd
        '';
      };
    };
  };

  swtpmModule = types.submodule {
    options = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Allows libvirtd to use swtpm to create an emulated TPM.
        '';
      };

      package = mkPackageOption pkgs "swtpm" { };
    };
  };

  qemuModule = types.submodule {
    options = {
      package = mkPackageOption pkgs "qemu" {
        extraDescription = ''
          `pkgs.qemu` can emulate alien architectures (e.g. aarch64 on x86)
          `pkgs.qemu_kvm` saves disk space allowing to emulate only host architectures.
        '';
      };

      runAsRoot = mkOption {
        type = types.bool;
        default = false;
        description = ''
          If true,  libvirtd runs qemu as root.
          If false, libvirtd runs qemu as unprivileged user qemu-libvirtd.
          Changing this option to false may cause file permission issues
          for existing guests. To fix these, manually change ownership
          of affected files in /var/lib/libvirt/qemu to qemu-libvirtd.
        '';
      };

      verbatimConfig = mkOption {
        type = types.lines;
        default = ''
          namespaces = []
        '';
        description = ''
          Contents written to the qemu configuration file, qemu.conf.
          Make sure to include a proper namespace configuration when
          supplying custom configuration.
        '';
      };

      ovmf = mkOption {
        type = ovmfModule;
        default = { };
        description = ''
          QEMU's OVMF options.
        '';
      };

      swtpm = mkOption {
        type = swtpmModule;
        default = { };
        description = ''
          QEMU's swtpm options.
        '';
      };

      vhostUserPackages = mkOption {
        type = types.listOf types.package;
        default = [ ];
        example = lib.literalExpression "[ pkgs.virtiofsd ]";
        description = ''
          Packages containing out-of-tree vhost-user drivers.
        '';
      };
    };
  };

  hooksModule = types.submodule {
    options = {
      daemon = mkOption {
        type = types.attrsOf types.path;
        default = { };
        description = ''
          Hooks that will be placed under /var/lib/libvirt/hooks/daemon.d/
          and called for daemon start/shutdown/SIGHUP events.
          Please see https://libvirt.org/hooks.html for documentation.
        '';
      };

      qemu = mkOption {
        type = types.attrsOf types.path;
        default = { };
        description = ''
          Hooks that will be placed under /var/lib/libvirt/hooks/qemu.d/
          and called for qemu domains begin/end/migrate events.
          Please see https://libvirt.org/hooks.html for documentation.
        '';
      };

      lxc = mkOption {
        type = types.attrsOf types.path;
        default = { };
        description = ''
          Hooks that will be placed under /var/lib/libvirt/hooks/lxc.d/
          and called for lxc domains begin/end events.
          Please see https://libvirt.org/hooks.html for documentation.
        '';
      };

      libxl = mkOption {
        type = types.attrsOf types.path;
        default = { };
        description = ''
          Hooks that will be placed under /var/lib/libvirt/hooks/libxl.d/
          and called for libxl-handled xen domains begin/end events.
          Please see https://libvirt.org/hooks.html for documentation.
        '';
      };

      network = mkOption {
        type = types.attrsOf types.path;
        default = { };
        description = ''
          Hooks that will be placed under /var/lib/libvirt/hooks/network.d/
          and called for networks begin/end events.
          Please see https://libvirt.org/hooks.html for documentation.
        '';
      };
    };
  };
in
{
  options.virtualisation.libvirtd = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        This option enables libvirtd, a daemon that manages
        virtual machines. Users in the "libvirtd" group can interact with
        the daemon (e.g. to start or stop VMs) using the
        {command}`virsh` command line tool, among others.
      '';
    };

    package = mkPackageOption pkgs "libvirt" { };

    extraOptions = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "--verbose" ];
      description = ''
        Extra command line arguments passed to libvirtd on startup.
      '';
    };

    onBoot = mkOption {
      type = types.enum [
        "start"
        "ignore"
      ];
      default = "start";
      description = ''
        Specifies the action to be done to / on the guests when the host boots.
        The "start" option starts all guests that were running prior to shutdown
        regardless of their autostart settings. The "ignore" option will not
        start the formerly running guest on boot. However, any guest marked as
        autostart will still be automatically started by libvirtd.
      '';
    };

    onShutdown = mkOption {
      type = types.enum [
        "shutdown"
        "suspend"
      ];
      default = "suspend";
      description = ''
        When shutting down / restarting the host what method should
        be used to gracefully halt the guests. Setting to "shutdown"
        will cause an ACPI shutdown of each guest. "suspend" will
        attempt to save the state of the guests ready to restore on boot.
      '';
    };

    parallelShutdown = mkOption {
      type = types.ints.unsigned;
      default = 0;
      description = ''
        Number of guests that will be shutdown concurrently, taking effect when onShutdown
        is set to "shutdown". If set to 0, guests will be shutdown one after another.
        Number of guests on shutdown at any time will not exceed number set in this
        variable.
      '';
    };

    shutdownTimeout = mkOption {
      type = types.ints.unsigned;
      default = 300;
      description = ''
        Number of seconds we're willing to wait for a guest to shut down.
        If parallel shutdown is enabled, this timeout applies as a timeout
        for shutting down all guests on a single URI defined in the variable URIS.
        If this is 0, then there is no time out (use with caution, as guests might not
        respond to a shutdown request).
      '';
    };

    startDelay = mkOption {
      type = types.ints.unsigned;
      default = 0;
      description = ''
        Number of seconds to wait between each guest start.
        If set to 0, all guests will start up in parallel.
      '';
    };

    allowedBridges = mkOption {
      type = types.listOf types.str;
      default = [ "virbr0" ];
      description = ''
        List of bridge devices that can be used by qemu:///session
      '';
    };

    qemu = mkOption {
      type = qemuModule;
      default = { };
      description = ''
        QEMU related options.
      '';
    };

    hooks = mkOption {
      type = hooksModule;
      default = { };
      description = ''
        Hooks related options.
      '';
    };

    sshProxy = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to configure OpenSSH to use the [SSH Proxy](https://libvirt.org/ssh-proxy.html).
      '';
    };
  };

  config = mkIf cfg.enable {
    services.dbus.enable = true;

    environment = {
      # this file is expected in /etc/qemu and not sysconfdir (/var/lib)
      etc."qemu/bridge.conf".text = concatMapStringsSep "\n" (e: "allow ${e}") cfg.allowedBridges;
      systemPackages = with pkgs; [
        libressl.nc
        config.networking.firewall.package
        cfg.package
        cfg.qemu.package
      ];
      etc.ethertypes.source = "${pkgs.iptables}/etc/ethertypes";
    };

    boot.kernelModules = [ "tun" ];

    users.groups.libvirtd.gid = config.ids.gids.libvirtd;

    # libvirtd runs qemu as this user and group by default
    users.extraGroups.qemu-libvirtd.gid = config.ids.gids.qemu-libvirtd;
    users.extraUsers.qemu-libvirtd = {
      uid = config.ids.uids.qemu-libvirtd;
      isNormalUser = false;
      group = "qemu-libvirtd";
    };

    security.wrappers.qemu-bridge-helper = {
      setuid = true;
      owner = "root";
      group = "root";
      source = "${cfg.qemu.package}/libexec/qemu-bridge-helper";
    };

    programs.ssh.extraConfig = mkIf cfg.sshProxy ''
      Include ${cfg.package}/etc/ssh/ssh_config.d/30-libvirt-ssh-proxy.conf
    '';

    runit.services = {
      libvirt-config = {
        run = ''
          for dir in nix-emulators nix-helpers nix-ovmf ; do
            mkdir -p /run/${dirName}/$dir
          done

          # Copy default libvirt network config .xml files to /var/lib
          # Files modified by the user will not be overwritten
          for i in $(cd ${cfg.package}/var/lib && echo \
              libvirt/qemu/networks/*.xml \
              libvirt/nwfilter/*.xml );
          do
              # Intended behavior
              # shellcheck disable=SC2174
              mkdir -p "/var/lib/$(dirname "$i")" -m 755
              if [ ! -e "/var/lib/$i" ]; then
                cp -pd "${cfg.package}/var/lib/$i" "/var/lib/$i"
              fi
          done

          # Copy generated qemu config to libvirt directory
          cp -f ${qemuConfigFile} /var/lib/${dirName}/qemu.conf

          # stable (not GC'able as in /nix/store) paths for using in <emulator> section of xml configs
          for emulator in ${cfg.package}/libexec/libvirt_lxc ${cfg.qemu.package}/bin/qemu-kvm ${cfg.qemu.package}/bin/qemu-system-*; do
            ln -s --force "$emulator" /run/${dirName}/nix-emulators/
          done

          ln -s --force ${cfg.qemu.package}/bin/qemu-pr-helper /run/${dirName}/nix-helpers/

          ${optionalString cfg.qemu.ovmf.enable (
            let
              ovmfpackage = pkgs.buildEnv {
                name = "qemu-ovmf";
                paths = cfg.qemu.ovmf.packages;
              };
            in
            ''
              ln -s --force ${ovmfpackage}/FV/AAVMF_CODE{,.ms}.fd /run/${dirName}/nix-ovmf/
              ln -s --force ${ovmfpackage}/FV/OVMF_CODE{,.ms}.fd /run/${dirName}/nix-ovmf/
              ln -s --force ${ovmfpackage}/FV/AAVMF_VARS{,.ms}.fd /run/${dirName}/nix-ovmf/
              ln -s --force ${ovmfpackage}/FV/OVMF_VARS{,.ms}.fd /run/${dirName}/nix-ovmf/
            ''
          )}

          # Symlink hooks to /var/lib/libvirt
          ${concatStringsSep "\n" (
            map (driver: ''
              mkdir -p /var/lib/${dirName}/hooks/${driver}.d
              rm -rf /var/lib/${dirName}/hooks/${driver}.d/*
              ${concatStringsSep "\n" (
                mapAttrsToList (
                  name: value: "ln -s --force ${value} /var/lib/${dirName}/hooks/${driver}.d/${name}"
                ) cfg.hooks.${driver}
              )}
            '') (attrNames cfg.hooks)
          )}

          mkdir -p /var/lib/qemu
          ln -s --force ${vhostUserCollection}/share/qemu/vhost-user /var/lib/qemu/vhost-user
          ln -s --force ${cfg.qemu.package}/share/qemu/firmware /var/lib/qemu/firmware
        '';
        oneShot = true;
        log.enable = true;
        log.sendTo = "127.0.0.1";
      };

      libvirt-guests = {
        path = with pkgs; [
          coreutils
          gawk
          cfg.package
        ];

        environment = {
          ON_BOOT = "${cfg.onBoot}";
          ON_SHUTDOWN = "${cfg.onShutdown}";
          PARALLEL_SHUTDOWN = "${toString cfg.parallelShutdown}";
          SHUTDOWN_TIMEOUT = "${toString cfg.shutdownTimeout}";
          START_DELAY = "${toString cfg.startDelay}";
        };

        run = ''
          waitForService dbus
          waitForService libvirt-config
          waitForService virtqemud

          mkdir -p /var/lock

          ${cfg.package}/libexec/libvirt-guests.sh start
        '';

        finish = ''
          ${cfg.package}/libexec/libvirt-guests.sh stop
        '';

        oneShot = true;
        onChange = "ignore";

        log.enable = true;
        log.sendTo = "127.0.0.1";
      };
    }
    // (listToAttrs (
      map (
        m:
        nameValuePair "virt${m}d" {
          path = [
            cfg.qemu.package
            pkgs.dmidecode
            pkgs.dnsmasq
            pkgs.netcat
          ] # libvirtd requires qemu-img to manage disk images
          ++ optional cfg.qemu.swtpm.enable cfg.qemu.swtpm.package;

          environment.LIBVIRTD_ARGS = concatStringsSep " " cfg.extraOptions;

          run = ''
            waitForService dbus
            waitForService libvirt-config

            exec ${cfg.package}/bin/virt${m}d
          '';

          killMode = "process";

          log.enable = true;
          log.sendTo = "127.0.0.1";
        }
      ) modules
    ));
  };
}
