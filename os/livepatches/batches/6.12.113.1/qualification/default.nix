{
  schemaVersion = 1;
  release = "6.12.113.1";
  requiredGenericProfiles = [
    "set/vendor-aged-transition"
    "set/vendor-busy-transition"
    "set/vendor-failure-recovery"
    "set/vendor-lifecycle"
  ];
  platforms = {
    amd.runnerClass = "amd-livepatch";
    intel.runnerClass = "intel-kvm";
  };
  profileSettings."set/vendor-aged-transition" = {
    developmentDwellSeconds = 300;
    releaseDwellSeconds = 1800;
    selectedEvidenceClass = "release";
  };
}
