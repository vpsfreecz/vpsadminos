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
    boot.isContainer = mkOption {
      type = types.bool;
      default = false;
    };
    boot.loader.grub.zfsSupport = mkOption {
      type = types.bool;
      default = false;
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
      description = "enable nix-daemon and a writeable store";
    };
    networking.hostName = mkOption {
      type = types.string;
      description = "machine hostname";
      default = "default";
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
    networking.dhcpd = mkOption {
      type = types.bool;
      description = "enable dhcpd to provide DHCP for guests";
      default = false;
    };
    networking.openDNS = mkOption {
      type = types.bool;
      description = "use OpenDNS servers";
      default = true;
    };
    networking.ntpdate = mkOption {
      type = types.bool;
      description = "use ntpdate to sync time";
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
      default = false;
    };
  };

####################
#                  #
#  Implementation  #
#                  #
####################

  config =
  let
    origKernel = pkgs.linux_4_15;
    myKernel = origKernel.override {
      extraConfig = ''
        EXPERT y
        CHECKPOINT_RESTORE y
        CFS_BANDWIDTH y
      '';
    };

    # we also need to override zfs/spl via linuxPackagesFor
    myLinuxPackages = (pkgs.linuxPackagesFor myKernel).extend (
      self: super: {
        zfs = super.zfsUnstable.overrideAttrs (oldAttrs: rec {
          name = pkgs.zfs.name;
          version = pkgs.zfs.version;
          src = pkgs.zfs.src;
          spl = self.spl;
        });

        spl = super.splUnstable;
      });
  in
  (lib.mkMerge [{
    boot.supportedFilesystems = [ "zfs" ];
    environment.shellAliases = {
      ll = "ls -l";
      attach = "lxc-attach --clear-env -n";
    };
    environment.systemPackages = lib.optional config.vpsadminos.nix pkgs.nix;
    nixpkgs.config = {
      packageOverrides = self: rec {
      };
    };
    environment.etc = {
      "nix/nix.conf".source = pkgs.runCommand "nix.conf" {} ''
        extraPaths=$(for i in $(cat ${pkgs.writeReferencesToFile pkgs.stdenv.shell}); do if test -d $i; then echo $i; fi; done)
        cat > $out << EOF
        build-use-sandbox = true
        build-users-group = nixbld
        build-sandbox-paths = /bin/sh=${pkgs.stdenv.shell} $(echo $extraPaths)
        build-max-jobs = 1
        build-cores = 4
        EOF
      '';
      bashrc.text = "export PATH=/run/current-system/sw/bin";
      profile.text = "export PATH=/run/current-system/sw/bin";
      "resolv.conf".text = "nameserver 10.0.2.3";
      "nsswitch.conf".text = ''
        hosts:     files  dns   myhostname mymachines
        networks:  files dns
      '';
      "services".source = pkgs.iana_etc + "/etc/services";
      # XXX: generate these on start
      "ssh/ssh_host_rsa_key.pub".source = ./ssh/ssh_host_rsa_key.pub;
      "ssh/ssh_host_rsa_key" = { mode = "0600"; source = ./ssh/ssh_host_rsa_key; };
      "ssh/ssh_host_ed25519_key.pub".source = ./ssh/ssh_host_ed25519_key.pub;
      "ssh/ssh_host_ed25519_key" = { mode = "0600"; source = ./ssh/ssh_host_ed25519_key; };
      "cgconfig.conf".text = ''
        mount {
          cpuset = /sys/fs/cgroup/cpuset;
          cpu = /sys/fs/cgroup/cpu,cpuacct;
          cpuacct = /sys/fs/cgroup/cpu,cpuacct;
          blkio = /sys/fs/cgroup/blkio;
          memory = /sys/fs/cgroup/memory;
          devices = /sys/fs/cgroup/devices;
          freezer = /sys/fs/cgroup/freezer;
          net_cls = /sys/fs/cgroup/net_cls;
          pids = /sys/fs/cgroup/pids;
          "name=systemd" = /sys/fs/cgroup/systemd;
        }
        group . {
          memory {
            memory.use_hierarchy = 1;
          }
        }
      '';
      # XXX: defined twice (for default.conf bellow with different idmap), refactor
      "lxc/user.conf".text = ''
          lxc.net.0.type = veth
          ${lib.optionalString config.networking.lxcbr "lxc.net.0.link = lxcbr0"}
          lxc.net.0.flags = up
          lxc.net.0.hwaddr = 00:16:3e:xx:xx:xx
          lxc.idmap = u 0 100000 65536
          lxc.idmap = g 0 100000 65536
          lxc.include = ${pkgs.lxcfs}/share/lxc/config/common.conf.d/00-lxcfs.conf
          lxc.apparmor.allow_incomplete = 1 
      '';
      "lxc/common.conf.d/00-lxcfs.conf".source = "${pkgs.lxcfs}/share/lxc/config/common.conf.d/00-lxcfs.conf";
    };

    boot.kernelParams = [ "systemConfig=${config.system.build.toplevel}" ];
    boot.kernelPackages = myLinuxPackages;
    boot.kernelModules = [
      "veth"
      "fuse"
      "e1000e"
      "igb"
      "ixgb"
      "ahci"
    ] ++ lib.optionals config.networking.nat [
      "ip6_tables"
      "ip6table_filter"
      "iptable_nat"
    ];

    security.apparmor.enable = true;

    virtualisation = {
      lxc = {
        enable = true;
        defaultConfig = ''
          lxc.net.0.type = veth
          ${lib.optionalString config.networking.lxcbr "lxc.net.0.link = lxcbr0"}
          lxc.net.0.flags = up
          lxc.net.0.hwaddr = 00:16:3e:xx:xx:xx
          lxc.idmap = u 0 666000 65536
          lxc.idmap = g 0 666000 65536
          lxc.include = ${pkgs.lxcfs}/share/lxc/config/common.conf.d/00-lxcfs.conf
          lxc.apparmor.allow_incomplete = 1
        '';
        # XXX: need this?
        systemConfig = ''
          #lxc.rootfs.backend = zfs
          #lxc.bdev.zfs.root = vault/sys/atom/var/lib/lxc
        '';
        usernetConfig = lib.optionalString config.networking.lxcbr ''
          root veth lxcbr0 10
        '';
        lxcfs.enable = true;
      };
    };

    system.build.earlyMountScript = pkgs.writeScript "dummy" ''
    '';
    system.build.runvm = pkgs.writeScript "runner" ''
      #!${pkgs.stdenv.shell}
      exec ${pkgs.qemu_kvm}/bin/qemu-kvm -name vpsadminos -m 10240 \
        -drive index=0,id=drive1,file=${config.system.build.squashfs},readonly,media=cdrom,format=raw,if=virtio \
        -kernel ${config.system.build.kernel}/bzImage -initrd ${config.system.build.initialRamdisk}/initrd -nographic \
        -append "console=ttyS0 ${toString config.boot.kernelParams} quiet panic=-1" -no-reboot \
        -device virtio-net,netdev=net0 \
        -netdev user,id=net0,net=10.0.2.0/24,host=10.0.2.2,dns=10.0.2.3,hostfwd=tcp::2222-:22
    '';

    system.build.dist = pkgs.runCommand "vpsadminos-dist" {} ''
      mkdir $out
      cp ${config.system.build.squashfs} $out/root.squashfs
      cp ${config.system.build.kernel}/*zImage $out/kernel
      cp ${config.system.build.initialRamdisk}/initrd $out/initrd
      echo "${builtins.unsafeDiscardStringContext (toString config.boot.kernelParams)}" > $out/command-line
    '';

    system.build.toplevel = pkgs.runCommand "vpsadminos" {
      activationScript = config.system.activationScripts.script;
    } ''
      mkdir $out
      cp ${config.system.build.bootStage2} $out/init
      substituteInPlace $out/init --subst-var-by systemConfig $out
      ln -s ${config.system.path} $out/sw
      ln -s ${config.system.modulesTree} $out/kernel-modules
      echo "$activationScript" > $out/activate
      substituteInPlace $out/activate --subst-var out
      chmod u+x $out/activate
      unset activationScript
    '';

    system.build.squashfs = pkgs.callPackage <nixpkgs/nixos/lib/make-squashfs.nix> {
      storeContents = [ config.system.build.toplevel ];
    };
  }

  (mkIf (config.networking.openDNS) {
    environment.etc."resolv.conf.tail".text = ''
    nameserver 208.67.222.222
    nameserver 208.67.220.220
    '';
  })

  (mkIf (config.networking.dhcpd) {
    environment.etc."dhcpd/dhcpd4.conf".text = ''
    authoritative;
    option routers 192.168.1.1;
    option domain-name-servers 208.67.222.222, 208.67.220.220;
    option subnet-mask 255.255.255.0;
    option broadcast-address 192.168.1.255;
    subnet 192.168.1.0 netmask 255.255.255.0 {
      range 192.168.1.100 192.168.1.200;
    }
    '';
  })
  ]);
}
