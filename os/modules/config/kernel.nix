{ pkgs, config, lib, ... }:
with lib;
let
  origKernel = config.boot.kernelPackage;

  availableKernels = import ../../packages/linux/availableKernels.nix { inherit pkgs; inherit lib; };

  # we also need to override zfs/spl via linuxPackagesFor
  myLinuxPackages = (pkgs.linuxPackagesFor origKernel).extend (
    self: super: {
      zfs = (super.callPackage ../../packages/zfs {
        configFile = "kernel";
        kernel = origKernel;
        rev = availableKernels.kernels.${config.boot.kernelVersion}.zfs.rev;
        sha256 = availableKernels.kernels.${config.boot.kernelVersion}.zfs.sha256;
       }).zfsStable;
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
      description = "TODO";
    };

    boot.kernelPackage = mkOption {
      type = types.package;
      description = "base linux kernel package";
      default = availableKernels.genKernelPackage config.boot.kernelVersion;
    };

    boot.zfsUserPackage = mkOption {
      type = types.package;
      description = "TODO";
      default = availableKernels.genZfsUserPackage config.boot.kernelVersion;
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
      "nf_nat"
      "nf_nat_h323"
      "nf_nat_pptp"
      "nf_nat_snmp_basic"
      "nf_nat_amanda"
      "nf_nat_ftp"
      "nf_nat_irc"
      "nf_nat_sip"
      "nf_nat_tftp"
      "nft_chain_nat"
      "nft_compat"
      "nft_ct"
      "nft_fib"
      "nft_fib_inet"
      "nft_fib_ipv4"
      "nft_fib_ipv6"
      "nft_limit"
      "nft_log"
      "nft_masq"
      "nft_nat"
      "nft_objref"
      "nft_redir"
      "nft_reject"
      "nft_reject_inet"
      "overlay"
      "veth"
      "wireguard"
    ];

    boot.initrd.kernelModules = lib.optionals config.boot.initrd.withHwSupport hwSupportModules;
  };
}
