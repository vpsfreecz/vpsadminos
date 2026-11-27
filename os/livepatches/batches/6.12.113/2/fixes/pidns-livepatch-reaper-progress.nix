{
  id = "pidns-livepatch-reaper-progress";
  patchIds = [
    "pidns-make-reaper-waits-freezable"
    "pidns-preserve-reaper-signal-progress"
    "signal-localize-no-notify-guard"
  ];
  provenance = {
    source = {
      repository = "vpsfreecz/linux";
      commit = "7d8430b9bc0d47578d0146d0d924c1d6ef355ba7";
    };
    status = "stable";
    upstream = "5c0985dd3c32fc2bbd0e8beaf13cf52cd97376a2";
    stable = "30b274508c743f243c82904954c4e416d7143d4c";
  };
  cves = [ "CVE-2026-99244" ];
  prerequisites = [
    "4b47107f1a80c809c80093e872bcaccdbae13db4"
    "4a52a339587ed193e1d956c9d609283ae3f7a377"
  ];
  functions = [
    {
      object = "vmlinux";
      symbol = "do_wait";
      sympos = 1;
    }
    {
      object = "vmlinux";
      symbol = "zap_pid_ns_processes";
      sympos = 0;
    }
  ];
  oracleIds = [ "pidns-livepatch-operation-safety" ];
}
