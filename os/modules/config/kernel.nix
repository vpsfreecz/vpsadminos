{ pkgs, config, lib, ... }:
with lib;
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
in {
  options = {
    boot.initrd.withHwSupport = mkOption {
      type = types.bool;
      default = true;
      description = "Include hardware support kernel modules in initrd (so e.g. zfs sees disks)";
    };

    boot.kernelPackage = mkOption {
      type = types.package;
      description = "base linux kernel package";
      default = pkgs.callPackage (import ../../packages/linux/default.nix) {};
      example = pkgs.linux_4_16;
    };
  };

  config = {
    boot.kernelParams = [
      "net.ifnames=0"
    ];

    boot.kernelPackages = myLinuxPackages;
    boot.kernelModules = hwSupportModules ++ [
      "br_netfilter"
      "fuse"
      "veth"
    ];

    boot.initrd.kernelModules = lib.optionals config.boot.initrd.withHwSupport hwSupportModules;
  };
}
