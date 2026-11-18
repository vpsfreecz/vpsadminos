{
  id = "io-uring-cancel-local-work";
  patchIds = [ "io-uring-cancel-stop-local-work-spin" ];
  provenance = {
    source = {
      repository = "stable/linux";
      commit = "8a241d7ca23be2695a1fbe587ee12eae061c31af";
    };
    status = "stable";
    upstream = "fddcf4c5321b3ea5f72166c3fd36a9d1c34f80c7";
    stable = "8a241d7ca23be2695a1fbe587ee12eae061c31af";
  };
  cves = [ "CVE-2026-99130" ];
  prerequisites = [ ];
  functions = [
    {
      object = "vmlinux";
      symbol = "io_uring_cancel_generic";
      sympos = 0;
    }
  ];
  oracleIds = [ "io-uring-cancel-operation-safety" ];
}
