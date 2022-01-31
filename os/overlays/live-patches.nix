self: super:
{
  livepatch-cpu-fakemask = super.callPackage ../packages/livepatches/fake-cpumask/default.nix {};
}
