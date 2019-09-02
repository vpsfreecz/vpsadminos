{
  "/proc/bus" = false;
  "/sys/block" = false;
  "/sys/bus" = false;
  "/sys/class" = {
    subdirs = {
      "mem" = true;
      "misc" = true;
      "net" = true;
      "tty" = true;
    };
  };
  "/sys/dev/block" = true;
  "/sys/devices" = {
    subdirs = {
      "/system" = {
        subdirs = {
          "/cpu" = true;
        };
      };
      "/virtual" = {
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
