self: super:
{
  machine-check = super.callPackage ../packages/machine-check {};

  osbench = super.callPackage ../packages/osbench {};
}
