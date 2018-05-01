{ config, pkgs, lib, ... }:

{
  # This is an example of customizing
  # pool creation and partitiong
  # for stage 1.
  #
  # We allow disk wipe for sda and sdb,
  # configure sfdisk partitioning to
  # create three partitions on both disks
  # and we use these for mirrored zfs
  # with logs and caches

  boot.zfs.pool = {
    wipe = [ "sda" "sdb" ];
    layout = "mirror sda1 sdb1";
    logs = "mirror sda2 sdb2";
    caches = "sda3 sdb3";
    partition = {
      sda = {
        p1 = { sizeGB=3; };
        p2 = { sizeGB=1; };
        p3 = {};
      };
      sdb = {
        p1 = { sizeGB=3; };
        p2 = { sizeGB=1; };
        p3 = {};
      };
    };
  };

  # It is also possible to define an action
  # to take if failure occurs in stage 1.
  # This allows for completely unattended installations
  # if pool is not present on the device.
  #
  # Be careful not to destroy your data with
  # wipe and this option enabled!
  #boot.predefinedFailAction = "n";

}
