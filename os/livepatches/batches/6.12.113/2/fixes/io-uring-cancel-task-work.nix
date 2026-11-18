{
  id = "io-uring-cancel-task-work";
  patchIds = [ "io-uring-limit-cancel-task-work" ];
  provenance = {
    source = {
      repository = "stable/linux";
      commit = "61c761fc21e00e45c33c2bb596be442d92fb8792";
    };
    status = "stable";
    upstream = "22e643e61b9b6299b42ff7d88bab48bccada8a5d";
    stable = "61c761fc21e00e45c33c2bb596be442d92fb8792";
  };
  cves = [ "CVE-2026-99254" ];
  prerequisites = [ "io-uring-cancel-local-work" ];
  functions = [
    {
      object = "vmlinux";
      symbol = "io_tctx_exit_cb";
      sympos = 1;
    }
    {
      object = "vmlinux";
      symbol = "io_ring_exit_work";
      sympos = 1;
    }
    {
      object = "vmlinux";
      symbol = "io_uring_cancel_generic";
      sympos = 0;
    }
  ];
  oracleIds = [ "io-uring-cancel-task-work-operation-safety" ];
}
