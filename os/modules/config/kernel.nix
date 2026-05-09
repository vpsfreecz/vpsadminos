{
  pkgs,
  config,
  lib,
  ...
}:
with lib;
let
  origKernel = config.boot.kernelPackage;
  zfsBuiltin = config.boot.zfsBuiltin;
  kernelForBuiltinsConfig = config.boot.kernelForBuiltinsConfig;
  moduleAutoload = config.boot.kernel.moduleAutoload;
  modprobeAction = if moduleAutoload.enable then "load" else "deny";

  kernelPackages = import ../../packages/linux/packages.nix { inherit config pkgs lib; };

  modprobeWrapper = pkgs.writeScript "kernel-modprobe-wrapper" ''
    #!${pkgs.runtimeShell}
    ${pkgs.util-linux}/bin/logger -t kernel.modprobe -- "action=${modprobeAction}" "$@"
    ${
      if moduleAutoload.enable then
        ''
          exec ${pkgs.kmod}/bin/modprobe "$@"
        ''
      else
        ''
          exit 1
        ''
    }
  '';

  kernelModprobe = if moduleAutoload.log then "${modprobeWrapper}" else "";

  overrideKernelModprobe = moduleAutoload.log || !moduleAutoload.enable;

  # we also need to override zfs/spl via linuxPackagesFor
  myLinuxPackages = (pkgs.linuxPackagesFor origKernel).extend (
    self: super: {
      zfs =
        if (!zfsBuiltin) then
          (super.callPackage ../../packages/zfs {
            configFile = "kernel";
            kernel = origKernel;
            rev = kernelPackages.kernels.${config.boot.kernelVersion}.zfs.rev;
            sha256 = kernelPackages.kernels.${config.boot.kernelVersion}.zfs.sha256;
          }).zfsStable
            { enableDebug = config.system.vpsadminos.zfsDebug; }
        else
          (super.stdenv.mkDerivation {
            name = "zfs";
            buildCommand = ''
              mkdir -p $out
            '';
          });
    }
  );

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
    "hid_generic"
    "hid_lenovo"
    "hid_apple"
    "hid_roccat"
    "hid_logitech_hidpp"
    "hid_logitech_dj"

    # PS2
    "pcips2"
    "atkbd"
    "i8042"
  ];

in
{
  options = {
    boot.initrd.withHwSupport = mkOption {
      type = types.bool;
      default = true;
      description = "Include hardware support kernel modules in initrd (so e.g. zfs sees disks)";
    };

    boot.kernelVersion = mkOption {
      type = types.str;
      default = kernelPackages.defaultVersion;
      description = "Linux kernel version from available-kernels.nix to use";
    };

    boot.kernelPackage = mkOption {
      type = types.package;
      description = "vpsAdminOS Linux kernel package";
      default =
        if zfsBuiltin then
          (kernelPackages.genKernelPackageWithZfsBuiltin {
            kernelVersion = config.boot.kernelVersion;
            zfsBuiltinPkg = config.boot.zfsBuiltinPkg;
          })
        else
          kernelPackages.genKernelPackage config.boot.kernelVersion;
    };

    boot.zfsUserPackage = mkOption {
      type = types.package;
      description = "ZFS userland package";
      default = kernelPackages.genZfsUserPackage config.boot.kernelVersion;
    };

    boot.kernelForBuiltinsConfig = mkOption {
      type = types.package;
      description = "Kernel package for builtins config";
      default = kernelPackages.genKernelPackage config.boot.kernelVersion;
    };

    boot.zfsBuiltin = mkOption {
      type = types.bool;
      description = "Build ZFS as a builtin module";
      default = true;
    };

    boot.zfsBuiltinPkg = mkOption {
      type = types.package;
      description = "ZFS builtin package";
      default = kernelPackages.genZfsBuiltinPackage kernelForBuiltinsConfig;
    };

    boot.kernel.moduleAutoload = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable kernel module autoloading through /proc/sys/kernel/modprobe.
        '';
      };

      log = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Log kernel module autoload requests and the action taken through a
          kernel.modprobe wrapper. When module autoloading is disabled, the
          wrapper logs the request and exits without loading the module.
        '';
      };
    };
  };

  config = {
    boot.kernelParams = [
      "net.ifnames=0"
      "cgroup.memory=nokmem"
    ];

    boot.kernelPackages = myLinuxPackages;
    boot.kernelModules = hwSupportModules ++ [
      "act_csum"
      "act_mirred"
      "af_alg"
      "af_packet"
      "af_packet_diag"
      "algif_hash"
      "algif_rng"
      "algif_skcipher"
      "asn1_encoder"
      "auth_rpcgss"
      "autofs4"
      "blowfish_common"
      "blowfish_generic"
      "br_netfilter"
      "bridge"
      "bsd_comp"
      "camellia_generic"
      "cast5_generic"
      "cast_common"
      "ceph"
      "cifs"
      "cifs_arc4"
      "cifs_md4"
      "cls_matchall"
      "cls_u32"
      "cmac"
      "crc16"
      "crc32c_generic"
      "cryptd"
      "crypto_simd"
      "crypto_user"
      "des_generic"
      "dm_mod"
      "dns_resolver"
      "dummy"
      "fuse"
      "grace"
      "gre"
      "ifb"
      "inet_diag"
      "ip6_tables"
      "ip6_udp_tunnel"
      "ip6t_REJECT"
      "ip6t_ah"
      "ip6t_rpfilter"
      "ip6t_rt"
      "ip6table_filter"
      "ip6table_mangle"
      "ip6table_nat"
      "ip6table_raw"
      "ip6table_security"
      "ip_gre"
      "ip_set"
      "ip_set_bitmap_port"
      "ip_set_hash_ip"
      "ip_set_hash_net"
      "ip_tables"
      "ip_tunnel"
      "ip_vs"
      "ip_vs_dh"
      "ip_vs_fo"
      "ip_vs_ftp"
      "ip_vs_lblc"
      "ip_vs_lblcr"
      "ip_vs_lc"
      "ip_vs_nq"
      "ip_vs_ovf"
      "ip_vs_pe_sip"
      "ip_vs_rr"
      "ip_vs_sed"
      "ip_vs_sh"
      "ip_vs_wlc"
      "ip_vs_wrr"
      "ipip"
      "ipt_REJECT"
      "ipt_rpfilter"
      "iptable_filter"
      "iptable_mangle"
      "iptable_nat"
      "iptable_raw"
      "iptable_security"
      "l2tp_core"
      "l2tp_netlink"
      "l2tp_ppp"
      "libceph"
      "libchacha"
      "libchacha20poly1305"
      "libcrc32c"
      "libcurve25519_generic"
      "libdes"
      "llc"
      "lockd"
      "loop"
      "md4"
      "netfs"
      "netlink_diag"
      "nf_conncount"
      "nf_conntrack"
      "nf_conntrack_amanda"
      "nf_conntrack_broadcast"
      "nf_conntrack_ftp"
      "nf_conntrack_h323"
      "nf_conntrack_irc"
      "nf_conntrack_netbios_ns"
      "nf_conntrack_netlink"
      "nf_conntrack_pptp"
      "nf_conntrack_sane"
      "nf_conntrack_sip"
      "nf_conntrack_snmp"
      "nf_conntrack_tftp"
      "nf_defrag_ipv4"
      "nf_defrag_ipv6"
      "nf_log_syslog"
      "nf_nat"
      "nf_nat_amanda"
      "nf_nat_ftp"
      "nf_nat_h323"
      "nf_nat_irc"
      "nf_nat_pptp"
      "nf_nat_sip"
      "nf_nat_snmp_basic"
      "nf_nat_tftp"
      "nf_reject_ipv4"
      "nf_reject_ipv6"
      "nf_tables"
      "nf_tproxy_ipv4"
      "nf_tproxy_ipv6"
      "nfnetlink"
      "nfnetlink_acct"
      "nfnetlink_log"
      "nfnetlink_queue"
      "nfs"
      "nfs_acl"
      "nfsd"
      "nfsv3"
      "nfsv4"
      "nft_chain_nat"
      "nft_compat"
      "nft_connlimit"
      "nft_ct"
      "nft_fib"
      "nft_fib_inet"
      "nft_fib_ipv4"
      "nft_fib_ipv6"
      "nft_limit"
      "nft_log"
      "nft_masq"
      "nft_nat"
      "nft_redir"
      "nft_reject"
      "nft_reject_inet"
      "nft_reject_ipv4"
      "nft_reject_ipv6"
      "nft_reject_netdev"
      "nls_ucs2_utils"
      "nls_utf8"
      "overlay"
      "polyval_generic"
      "ppp_async"
      "ppp_deflate"
      "ppp_generic"
      "pppox"
      "raw_diag"
      "rmd160"
      "rpcsec_gss_krb5"
      "sch_cake"
      "sch_fq"
      "sch_htb"
      "sch_ingress"
      "sctp"
      "sctp_diag"
      "serpent_generic"
      "sha1_generic"
      "slhc"
      "sm3"
      "sm3_generic"
      "sm4"
      "sm4_generic"
      "squashfs"
      "stp"
      "sunrpc"
      "tcp_bbr"
      "tcp_diag"
      "ts_kmp"
      "tun"
      "twofish_common"
      "twofish_generic"
      "udp_diag"
      "udp_tunnel"
      "unix_diag"
      "veth"
      "virtiofs"
      "vrf"
      "vsock"
      "vsock_diag"
      "vsock_loopback"
      "vxlan"
      "wireguard"
      "x_tables"
      "xcbc"
      "xt_AUDIT"
      "xt_CHECKSUM"
      "xt_CLASSIFY"
      "xt_CT"
      "xt_DSCP"
      "xt_LOG"
      "xt_MASQUERADE"
      "xt_NFLOG"
      "xt_NFQUEUE"
      "xt_REDIRECT"
      "xt_TCPMSS"
      "xt_TPROXY"
      "xt_TRACE"
      "xt_addrtype"
      "xt_bpf"
      "xt_cgroup"
      "xt_comment"
      "xt_connlimit"
      "xt_connmark"
      "xt_conntrack"
      "xt_dscp"
      "xt_hashlimit"
      "xt_helper"
      "xt_hl"
      "xt_iprange"
      "xt_ipvs"
      "xt_length"
      "xt_limit"
      "xt_mark"
      "xt_multiport"
      "xt_nat"
      "xt_nfacct"
      "xt_owner"
      "xt_physdev"
      "xt_pkttype"
      "xt_policy"
      "xt_realm"
      "xt_recent"
      "xt_sctp"
      "xt_set"
      "xt_state"
      "xt_statistic"
      "xt_tcpmss"
      "xt_tcpudp"
      "xt_time"
      "xt_u32"
    ];

    boot.extraModprobeConfig = ''
      # nf_conntrack_amanda asks the kernel to autoload ts_kmp during module
      # init. Make the dependency explicit because module autoloading is
      # disabled, and boot.kernelModules is sorted by the NixOS option type.
      softdep nf_conntrack_amanda pre: ts_kmp
    '';

    boot.initrd.kernelModules = lib.optionals config.boot.initrd.withHwSupport hwSupportModules;

    boot.kernel.sysctl."kernel.modprobe" = mkIf overrideKernelModprobe kernelModprobe;

    system.activationScripts.modprobe = mkIf overrideKernelModprobe (
      mkForce (
        stringAfter [ "specialfs" ] ''
          # NixOS' modprobe activation script writes the plain kmod path here
          # before sysctl is applied. Override it whenever module autoloading
          # should be denied or logged during activation and early boot.
          printf '%s\n' ${escapeShellArg kernelModprobe} > /proc/sys/kernel/modprobe
        ''
      )
    );
  };
}
