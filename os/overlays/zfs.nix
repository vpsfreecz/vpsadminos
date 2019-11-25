self: super:
{
  zfs = (super.callPackage ../packages/zfs {
    configFile = "user";
  }).zfsStable;
}
