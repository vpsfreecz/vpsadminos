{ batchLib }:

{
  batch = {
    release = "6.12.113.3";
    kernelVersion = "6.12.113";
    payloadRevision = 1;
    mode = "additive";
    build = {
      targets = [ "vmlinux" ];
      expected = {
        callbacks = [ ];
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
        imports = [
          ".klp.sym.vmlinux.__SCK__cond_resched,0"
          ".klp.sym.vmlinux.__inet_csk_reqsk_queue_drop,1"
          ".klp.sym.vmlinux.inet_child_forget,1"
          ".klp.sym.vmlinux.inet_ehash_insert,0"
          ".klp.sym.vmlinux.inet_reqsk_clone,1"
          ".klp.sym.vmlinux.tcp_ecn_create_request,1"
          ".klp.sym.vmlinux.tcp_openreq_init_rwin,0"
          ".klp.sym.vmlinux.tcp_peer_is_proven,0"
          ".klp.sym.vmlinux.tcp_syn_flood_action,1"
          ".klp.sym.vmlinux.tcp_timeout_init.constprop.0,1"
          ".klp.sym.vmlinux.tcp_try_fastopen,0"
          ".klp.sym.vmlinux.uts_proc_notify,0"
          ".klp.sym.vmlinux.uts_sem,0"
        ];
        relocations = [
          ".klp.rela.vmlinux..static_call_sites"
          ".klp.rela.vmlinux..text"
        ];
        states = [ ];
      };
    };
    fixes = batchLib.discoverFixes ./fixes;
    patches = import ./series.nix;
    lineage = {
      predecessorBatch = {
        release = "6.12.113.2";
        payloadRevision = 1;
      };
      functions = [ ];
      states = [ ];
    };
    runtime = {
      prevention = "stop failed migrated request timers and use refcounted request cleanup";
      removal = "remove only after the lookup tier is removed and its reverse transition converges";
      recovery = "does not repair requests freed before the lifetime tier converges";
    };
  };

  qualification = import ./qualification;

  documentation = {
    page = "os/livepatches/6.12.113";
    anchor = "release-6-12-113-3";
  };
}
