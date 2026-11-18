{
  id = "tcp-reqsk-refcount-cleanup-preparation";
  patchIds = [ "tcp-refcount-failed-reqsk-cleanup" ];
  provenance = {
    source = {
      repository = "vpsfreecz/linux";
      commit = "f19526fa0c6573f82828edf109f471f30e3c987c";
    };
    status = "stable";
    upstream = "4e2b3ef19e0e04adca38442f07dd6bc93c712bf1";
    stable = "d69100340b4cae08d40f898f1b601032403f6be6";
  };
  cves = [ ];
  prerequisites = [ "tcp-reqsk-migration-timer-lifetime" ];
  functions = [
    {
      object = "vmlinux";
      symbol = "inet_csk_complete_hashdance";
      sympos = 0;
    }
    {
      object = "vmlinux";
      symbol = "inet_csk_listen_stop";
      sympos = 0;
    }
    {
      object = "vmlinux";
      symbol = "reqsk_timer_handler";
      sympos = 1;
    }
    {
      object = "vmlinux";
      symbol = "tcp_conn_request";
      sympos = 0;
    }
    {
      object = "vmlinux";
      symbol = "tcp_get_cookie_sock";
      sympos = 0;
    }
  ];
  oracleIds = [ "tcp-reqsk-refcount-cleanup-operation-safety" ];
}
