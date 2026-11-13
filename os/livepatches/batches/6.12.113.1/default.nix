{ batchLib }:

{
  batch = {
    release = "6.12.113.1";
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
            symbol = "nfs_free_server";
            sympos = 0;
          }
          {
            object = "vmlinux";
            symbol = "nfs_init_server.isra.0";
            sympos = 1;
          }
          {
            object = "vmlinux";
            symbol = "shutdown_store";
            sympos = 1;
          }
        ];
        imports = [
          ".klp.sym.vmlinux.delayed_free,1"
          ".klp.sym.vmlinux.nfs_put_client.part.0,1"
          ".klp.sym.vmlinux.nfs_release_automount_timer,0"
          ".klp.sym.vmlinux.nfs_start_lockd,1"
          ".klp.sym.vmlinux.nfs_sysfs_remove_server,0"
          ".klp.sym.vmlinux.s_sysfs_ids,1"
          ".klp.sym.vmlinux.shutdown_match_client,1"
          ".klp.sym.vmlinux.uts_proc_notify,0"
          ".klp.sym.vmlinux.uts_sem,0"
        ];
        relocations = [ ".klp.rela.vmlinux..text" ];
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
      bootAutoload = false;
      prevention = "drain server sysfs callbacks before releasing NFS client state";
      removal = "disable and remove only after the reverse transition converges";
      recovery = "does not repair already-freed clients or interrupted shutdown work";
    };
  };

  qualification = import ./qualification;

  documentation = {
    page = "os/livepatches/6.12.113";
    anchor = "release-6-12-113-1";
  };
}
