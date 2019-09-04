{
  "/proc/bus" = false;
  "/sys/block" = false;
  "/sys/bus" = {
    subdirs = {
      # Needed by libvirt for libpciaccess
      "pci" = true;
    };
  };
  "/sys/class" = {
    subdirs = {
      "mem" = true;
      "misc" = true;
      "net" = true;

      # Needed by libvirt for libpciaccess
      "pci_bus" = true;

      "tty" = true;
    };
  };
  "/sys/dev/block" = true;
  "/sys/devices" = {
    subdirs = {
      # Needed by libvirt for libpciaccess
      "pci*" = true;

      "system" = {
        subdirs = {
          "cpu" = true;

          # Needed by libvirt to calculate total memory
          "node" = true;
        };
      };
      "virtual" = {
        subdirs = {
          "mem" = true;
          "misc" = true;
          "net" = true;
          "tty" = true;
        };
      };
    };
  };
  "/sys/firmware" = false;
  "/sys/module" = {
    subdirs = {
      "*" = {
        default = true;
        subdirs = {
          "sections" = false;
        };
      };
    };
  };
  "/sys/power" = false;
}
