{ pkgs, config, lib, ... }:
with lib;
let
  origKernel = config.boot.kernelPackage;
  zfsBuiltin = config.boot.zfsBuiltin;
  kernelForBuiltinsConfig = config.boot.kernelForBuiltinsConfig;

  availableKernels = import ../../packages/linux/availableKernels.nix { inherit pkgs; inherit lib; };

  # we also need to override zfs/spl via linuxPackagesFor
    myLinuxPackages = (pkgs.linuxPackagesFor origKernel).extend (
    self: super:
      {
        zfs = if (!zfsBuiltin)
          then (super.callPackage ../../packages/zfs {
              configFile = "kernel";
              kernel = origKernel;
              rev = availableKernels.kernels.${config.boot.kernelVersion}.zfs.rev;
              sha256 = availableKernels.kernels.${config.boot.kernelVersion}.zfs.sha256;
            }).zfsStable
          else (super.stdenv.mkDerivation {
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
    "hid_generic" "hid_lenovo" "hid_apple" "hid_roccat"
    "hid_logitech_hidpp" "hid_logitech_dj"

    # PS2
    "pcips2" "atkbd" "i8042"
  ];
in {
  options = {
    boot.initrd.withHwSupport = mkOption {
      type = types.bool;
      default = true;
      description = "Include hardware support kernel modules in initrd (so e.g. zfs sees disks)";
    };

    boot.kernelVersion = mkOption {
      type = types.str;
      default = availableKernels.defaultVersion;
      description = "Linux kernel version from availableKernels.nix to use";
    };

    boot.kernelPackage = mkOption {
      type = types.package;
      description = "vpsAdminOS Linux kernel package";
      default = if zfsBuiltin
                then (availableKernels.genKernelPackageWithZfsBuiltin {
                  kernelVersion = config.boot.kernelVersion;
                  zfsBuiltinPkg = config.boot.zfsBuiltinPkg;
                })
                else availableKernels.genKernelPackage config.boot.kernelVersion;
    };

    boot.zfsUserPackage = mkOption {
      type = types.package;
      description = "ZFS userland package";
      default = availableKernels.genZfsUserPackage config.boot.kernelVersion;
    };

    boot.kernelForBuiltinsConfig = mkOption {
      type = types.package;
      description = "Kernel package for builtins config";
      default = availableKernels.genKernelPackage config.boot.kernelVersion;
    };

    boot.zfsBuiltin = mkOption {
      type = types.bool;
      description = "Build ZFS as a builtin module";
      default = true;
    };

    boot.zfsBuiltinPkg = mkOption {
      type = types.package;
      description = "ZFS builtin package";
      default = availableKernels.genZfsBuiltinPackage kernelForBuiltinsConfig;
    };
  };

  config = {
    boot.kernelParams = [
      "net.ifnames=0"
      "cgroup.memory=nokmem"
    ];

    boot.kernelPackages = myLinuxPackages;
    boot.kernelModules = hwSupportModules ++ [
      "br_netfilter"
      "ceph"
      "fuse"
      "ip_gre"
      "ip_tables"
      "ip6_tables"
      "iptable_nat"
      "ip6table_nat"
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
      "nfsd"
      "nfsv3"
      "nfsv4"
      "overlay"
      "sunrpc"
      "veth"
      "wireguard"
      "nf_conncount"
      "nf_conntrack"
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
      "nf_dup_ipv4"
      "nf_dup_ipv6"
      "nf_dup_netde"
      "nf_flow_table"
      "nf_flow_table_inet"
      "nf_log_syslog"
      "nf_nat"
      "nf_nat_ftp"
      "nf_nat_h323"
      "nf_nat_irc"
      "nf_nat_pptp"
      "nf_nat_sip"
      "nf_nat_snmp_basic"
      "nf_nat_tftp"
      "nf_reject_ipv4"
      "nf_reject_ipv6"
      "nf_socket_ipv4"
      "nf_socket_ipv6"
      "nf_synproxy_core"
      "nf_tables"
      "nft_chain_nat"
      "nft_compat"
      "nft_connlimit"
      "nft_ct"
      "nft_dup_ipv4"
      "nft_dup_ipv6"
      "nft_dup_netdev"
      "nft_fib"
      "nft_fib_inet"
      "nft_fib_ipv4"
      "nft_fib_ipv6"
      "nft_fib_netdev"
      "nft_flow_offload"
      "nft_fwd_netdev"
      "nft_hash"
      "nft_limit"
      "nft_log"
      "nft_masq"
      "nft_nat"
      "nft_numgen"
      "nft_osf"
      "nf_tproxy_ipv4"
      "nf_tproxy_ipv6"
      "nft_queue"
      "nft_quota"
      "nft_redir"
      "nft_reject"
      "nft_reject_inet"
      "nft_reject_ipv4"
      "nft_reject_ipv6"
      "nft_reject_netdev"
      "nft_socket"
      "nft_synproxy"
      "nft_tproxy"
      "nft_tunnel"
      "nft_xfrm"
      "xt_addrtype"
      "xt_AUDIT"
      "xt_bpf"
      "xt_cgroup"
      "xt_CHECKSUM"
      "xt_CLASSIFY"
      "xt_cluster"
      "xt_comment"
      "xt_connbytes"
      "xt_connlabel"
      "xt_connlimit"
      "xt_connmark"
      "xt_CONNSECMARK"
      "xt_conntrack"
      "xt_cpu"
      "xt_CT"
      "xt_dccp"
      "xt_devgroup"
      "xt_dscp"
      "xt_DSCP"
      "xt_ecn"
      "xt_esp"
      "xt_hashlimit"
      "xt_helper"
      "xt_hl"
      "xt_HL"
      "xt_HMARK"
      "xt_IDLETIMER"
      "xt_ipcomp"
      "xt_iprange"
      "xt_ipvs"
      "xt_l2tp"
      "xt_LED"
      "xt_length"
      "xt_limit"
      "xt_LOG"
      "xt_mac"
      "xt_mark"
      "xt_MASQUERADE"
      "xt_multiport"
      "xt_nat"
      "xt_NETMAP"
      "xt_nfacct"
      "xt_NFLOG"
      "xt_NFQUEUE"
      "xt_osf"
      "xt_owner"
      "xt_physdev"
      "xt_pkttype"
      "xt_policy"
      "xt_quota"
      "xt_rateest"
      "xt_RATEEST"
      "xt_realm"
      "xt_recent"
      "xt_REDIRECT"
      "xt_sctp"
      "xt_SECMARK"
      "xt_set"
      "xt_socket"
      "xt_state"
      "xt_statistic"
      "xt_string"
      "xt_tcpmss"
      "xt_TCPMSS"
      "xt_TCPOPTSTRIP"
      "xt_tcpudp"
      "xt_TEE"
      "xt_time"
      "xt_TPROXY"
      "xt_TRACE"
      "xt_u32"
    ];

    boot.initrd.kernelModules = lib.optionals config.boot.initrd.withHwSupport hwSupportModules;
  };
}
