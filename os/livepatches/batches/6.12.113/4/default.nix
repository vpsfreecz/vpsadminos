{ batchLib }:

{
  batch = {
    release = "6.12.113.4";
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
            symbol = "__inet6_lookup_established";
            sympos = 0;
          }
          {
            object = "vmlinux";
            symbol = "__inet_lookup_established";
            sympos = 0;
          }
        ];
        imports = [
          ".klp.sym.vmlinux.uts_proc_notify,0"
          ".klp.sym.vmlinux.uts_sem,0"
        ];
        relocations = [
          ".klp.rela.vmlinux..text"
        ];
        states = [ ];
      };
    };
    fixes = batchLib.discoverFixes ./fixes;
    patches = import ./series.nix;
    lineage = {
      predecessorBatch = {
        release = "6.12.113.3";
        payloadRevision = 1;
      };
      functions = [ ];
      states = [ ];
    };
    runtime = {
      prevention = "reject unhashed IPv4 and IPv6 requests after taking a transient reference";
      removal = "remove and converge this lookup tier before removing the lifetime tier";
      recovery = "does not repair request lifetime damage that predates lookup convergence";
    };
  };

  qualification = import ./qualification;

  documentation = {
    page = "os/livepatches/6.12.113";
    anchor = "release-6-12-113-4";
  };
}
