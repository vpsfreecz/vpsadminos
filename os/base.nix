{ pkgs, config, lib, ... }:

with lib;

####################
#                  #
#    Interface     #
#                  #
####################

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
    system.secretsDir = mkOption {
      type = types.nullOr types.string;
      default = null;
      description = ''
        Path to a directory containing secret keys and other files that should
        not be stored in the Nix store. The directory's base name has to be
        <literal>secrets</literal>.

        If the sandbox is enabled (<literal>nix.useSandbox = true;</literal>)
        on the build machine, you need to add your directory with secrets
        to <literal>nix.sandboxPaths</literal> and then set this option to the
        path within the sandbox. For example, if your secrets on the build
        machine are stored in <literal>/home/vpsadminos/secrets</literal>, you
        could set
        <literal>nix.sandboxPaths = [ "/secrets=/home/vpsadminos/secrets" ];</literal>
        on the build machine and <literal>system.secretsDir = "/secrets";</literal>
        in vpsAdminOS config.
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
    boot.initrd.withHwSupport = mkOption {
      type = types.bool;
      default = true;
      description = "Include hardware support kernel modules in initrd (so e.g. zfs sees disks)";
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
    hardware.firmware = mkOption {
      type = types.listOf types.package;
      default = [];
      apply = list: pkgs.buildEnv {
        name = "firmware";
        paths = list;
        pathsToLink = [ "/lib/firmware" ];
        ignoreCollisions = true;
      };
    };
    vpsadminos.nix = mkOption {
      type = types.bool;
      default = true;
      description = "enable nix-daemon and a writeable store";
    };
    networking.hostName = mkOption {
      type = types.string;
      description = "machine hostname";
      default = "default";
    };
    networking.preConfig = mkOption {
      type = types.lines;
      description = "Set of commands run prior to any other network configuration";
      default = "";
    };
    networking.custom = mkOption {
      type = types.lines;
      description = "Custom set of commands used to set-up networking";
      default = "";
      example = "
        ip addr add 10.0.0.1 dev ix0
        ip link set ix0 up
      ";
    };
    networking.static.enable = mkOption {
      type = types.bool;
      description = "use static networking configuration";
      default = false;
    };
    networking.static.interface = mkOption {
      type = types.string;
      description = "interface for static networking configuration";
      default = "eth0";
    };
    networking.static.ip = mkOption {
      type = types.string;
      description = "IP address for static networking configuration";
      default = "10.0.2.15";
    };
    networking.static.route = mkOption {
      type = types.string;
      description = "route";
      default = "10.0.2.0/24";
    };
    networking.static.gw = mkOption {
      type = types.string;
      description = "gateway IP address for static networking configuration";
      default = "10.0.2.2";
    };
    networking.dhcp = mkOption {
      type = types.bool;
      description = "use DHCP to obtain IP";
      default = false;
    };
    networking.lxcbr = mkOption {
      type = types.bool;
      description = "create lxc bridge interface";
      default = false;
    };
    networking.nat = mkOption {
      type = types.bool;
      description = "enable NAT for containers";
      default = true;
    };
    boot.kernelPackage = mkOption {
      type = types.package;
      description = "base linux kernel package";
      default = pkgs.callPackage (import ./packages/linux/default.nix) {};
      example = pkgs.linux_4_16;
    };
  };

####################
#                  #
#  Implementation  #
#                  #
####################

  config =
  let
    origKernel = config.boot.kernelPackage;

    # we also need to override zfs/spl via linuxPackagesFor
    myLinuxPackages = (pkgs.linuxPackagesFor origKernel).extend (
      self: super: {
        zfs = super.zfsUnstable.overrideAttrs (oldAttrs: rec {
          name = pkgs.zfs.name;
          version = pkgs.zfs.version;
          src = pkgs.zfs.src;
          spl = null;
        });
      });

    hwSupportModules = [

      # SATA/PATA/NVME
      "ahci"
      "sata_nv"
      "sata_via"
      "sata_sis"
      "sata_uli"
      "nvme"
      "isci"

      # Standard SCSI stuff.
      "sd_mod"
      "sr_mod"

      # Support USB keyboards, in case the boot fails and we only have
      # a USB keyboard, or for LUKS passphrase prompt.
      "uhci_hcd"
      "ehci_hcd"
      "ehci_pci"
      "ohci_hcd"
      "ohci_pci"
      "xhci_hcd"
      "xhci_pci"
      "usbhid"
      "hid_generic" "hid_lenovo" "hid_apple" "hid_roccat"
      "hid_logitech_hidpp" "hid_logitech_dj"

      # PS2
      "pcips2" "atkbd" "i8042"
    ];

    cfg = config.system;

  in

  (lib.mkMerge [{
    assertions = [
      {
        assertion = config.system.secretsDir == null
                    || (baseNameOf config.system.secretsDir) == "secrets";
        message = "Base name of system.secretsDir has to be 'secrets'";
      }
    ];

    environment.shellAliases = {
      ll = "ls -l";
      vim = "vi";
    };
    environment.systemPackages = lib.optional config.vpsadminos.nix pkgs.nix;
    nixpkgs.config = {
      packageOverrides = self: rec {
      };
    };
    i18n = {
      defaultLocale = "en_US.UTF-8";
      supportedLocales = [ "en_US.UTF-8/UTF-8" ];
    };
    environment.etc = {
      "nsswitch.conf".text = ''
        hosts:     files  dns   myhostname mymachines
        networks:  files dns
      '';
      "cgconfig.conf".text = ''
        mount {
          cpuset = /sys/fs/cgroup/cpuset;
          cpu = /sys/fs/cgroup/cpu,cpuacct;
          cpuacct = /sys/fs/cgroup/cpu,cpuacct;
          blkio = /sys/fs/cgroup/blkio;
          memory = /sys/fs/cgroup/memory;
          devices = /sys/fs/cgroup/devices;
          freezer = /sys/fs/cgroup/freezer;
          net_cls = /sys/fs/cgroup/net_cls,net_prio;
          net_prio = /sys/fs/cgroup/net_cls,net_prio;
          pids = /sys/fs/cgroup/pids;
          perf_event = /sys/fs/cgroup/perf_event;
          rdma = /sys/fs/cgroup/rdma;
          hugetlb = /sys/fs/cgroup/hugetlb;
          cglimit = /sys/fs/cgroup/cglimit;
          "name=systemd" = /sys/fs/cgroup/systemd;
        }
        group . {
          memory {
            memory.use_hierarchy = 1;
          }
        }
      '';
      "lxc/common.conf.d/00-lxcfs.conf".source = "${pkgs.lxcfs}/share/lxc/config/common.conf.d/00-lxcfs.conf";
      # needed for osctl to access distro specific configs
      "lxc/config".source = "${pkgs.lxc}/share/lxc/config";

       # /etc/services: TCP/UDP port assignments.
      "services".source = pkgs.iana-etc + "/etc/services";
      # /etc/protocols: IP protocol numbers.
      "protocols".source  = pkgs.iana-etc + "/etc/protocols";
      # /etc/rpc: RPC program numbers.
      "rpc".source = pkgs.glibc.out + "/etc/rpc";
    };

    boot.kernelParams = [
      "net.ifnames=0"
    ];

    boot.kernelPackages = myLinuxPackages;
    boot.kernelModules = hwSupportModules ++ [
      "br_netfilter"
      "fuse"
      "veth"
    ] ++ lib.optionals config.networking.nat [
      "ip_tables"
      "iptable_nat"
      "ip6_tables"
      "ip6table_nat"
    ];

    boot.initrd.kernelModules = lib.optionals config.boot.initrd.withHwSupport hwSupportModules;

    boot.kernel.sysctl = {
      "kernel.dmesg_restrict" = true;
    };

    security.apparmor.enable = true;

    virtualisation = {
      lxc = {
        enable = true;
        usernetConfig = lib.optionalString config.networking.lxcbr ''
          root veth lxcbr0 10
        '';
        lxcfs.enable = true;
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

    system.activationScripts = {
      secrets = {
        text = ''
          if [ -d /nix/store/secrets ] ; then
            [ -d /var/secrets ] && rm -rf /var/secrets
            mv /nix/store/secrets /var/secrets
          fi
        '';
        deps = [];
      };
    };

    security.wrappers = {
      lxc-user-nic.source = "${pkgs.lxc}/libexec/lxc/lxc-user-nic";
    };

    system.build.toplevel = let
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
        substituteAll ${./lib/switch-to-configuration.rb} $out/bin/switch-to-configuration
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

    system.build.squashfs = pkgs.callPackage ./lib/make-squashfs.nix {
      storeContents = [ config.system.build.toplevel ];
      secretsDir = config.system.secretsDir;
    };

    system.build.kernelParams = config.boot.kernelParams;

    # Needed for nixops send-keys
    users.groups.keys.gid = config.ids.gids.keys;
  }
  ]);
}
