{
  id = "io-waitid-request-ownership";
  patchIds = [ "io-uring-waitid-own-request-before-head-clear" ];
  provenance = {
    source = {
      repository = "vpsfreecz/linux";
      commit = "43dbddcc2b98635014f3af37ad712d38991b92dd";
    };
    status = "stable";
    upstream = "c254eec4364b9f4b4cbdce43be3fb4df5a651a70";
    stable = "bf01da1a9cca4a54e5c30b8344e52c26afb87be7";
  };
  cves = [ "CVE-2026-99231" ];
  prerequisites = [ ];
  functions = [
    {
      object = "vmlinux";
      symbol = "io_waitid_wait";
      sympos = 1;
    }
  ];
  oracleIds = [ "io-waitid-operation-safety" ];
}
