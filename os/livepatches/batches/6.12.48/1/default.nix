{ batchLib }:

{
  batch = {
    release = "6.12.48.1";
    kernelVersion = "6.12.48";
    payloadRevision = 1;
    mode = "additive";
    build = {
      targets = [
        "vmlinux"
        "fs/nfsd/nfsd.ko"
        "net/sunrpc/auth_gss/auth_rpcgss.ko"
      ];
      expected = {
        callbacks = [ ];
        functions = [
          {
            object = "nfsd";
            symbol = "nfsd4_sequence";
            sympos = 0;
          }
        ];
        imports = [
          ".klp.sym.nfsd.__SCT__tp_func_nfsd_seq4_status,0"
          ".klp.sym.nfsd.__SCT__tp_func_nfsd_slot_seqid_sequence,0"
          ".klp.sym.nfsd.__tracepoint_nfsd_seq4_status,0"
          ".klp.sym.nfsd.__tracepoint_nfsd_slot_seqid_sequence,0"
          ".klp.sym.nfsd.find_in_sessionid_hashtbl,1"
          ".klp.sym.nfsd.nfsd4_conn_lost,1"
          ".klp.sym.nfsd.nfsd4_encode_operation,0"
          ".klp.sym.nfsd.nfsd4_max_reply,0"
          ".klp.sym.nfsd.nfsd4_put_session_locked,1"
          ".klp.sym.nfsd.nfsd_net_id,0"
          ".klp.sym.nfsd.same_creds,1"
          ".klp.sym.vmlinux.uts_proc_notify,0"
          ".klp.sym.vmlinux.uts_sem,0"
        ];
        relocations = [
          ".klp.rela.nfsd..text"
          ".klp.rela.vmlinux..text"
        ];
        states = [ ];
      };
    };
    fixes = batchLib.discoverFixes ./fixes;
    patches = import ./series.nix;
    lineage = {
      predecessorBatch = null;
      functions = [ ];
      states = [ ];
    };
    runtime = {
      prevention = "reject undersized NFSv4 SEQUENCE replies before accepting a slot";
      removal = "disable and remove only after the reverse transition converges";
      recovery = "does not repair previously corrupted NFS session or reply-cache state";
    };
  };

  qualification = import ./qualification;

  documentation = {
    page = "os/livepatches/6.12.48";
    anchor = "release-6-12-48-1";
  };
}
