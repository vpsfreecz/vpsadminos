{
  schemaVersion = 1;
  release = "6.12.113.1";
  requiredGenericProfiles = [
    "set/vendor-busy-transition"
    "set/vendor-failure-recovery"
    "set/vendor-lifecycle"
  ];
  platforms = {
    amd.runnerClass = "amd-livepatch";
    intel.runnerClass = "intel-kvm";
  };
}
