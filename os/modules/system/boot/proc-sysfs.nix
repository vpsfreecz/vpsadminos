{
  "/proc/bus" = false;
  "/sys/block" = false;
  "/sys/bus" = {
    subdirs = {
      "pci" = true;
    };
  };
  "/sys/class" = {
    subdirs = {
      "mem" = true;
      "misc" = true;
      "net" = true;
      "pci_bus" = true;
      "tty" = true;
    };
  };
  "/sys/dev/block" = true;
  "/sys/devices" = {
    subdirs = {
      "pci*" = true;
      "system" = {
        subdirs = {
          "cpu" = true;
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
  "/sys/power" = false;
}
