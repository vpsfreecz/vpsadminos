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
            symbol = "function_a";
            sympos = 0;
          }
          {
            object = "vmlinux";
            symbol = "function_b";
            sympos = 0;
          }
        ];
        imports = [ ];
        relocations = [ ];
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
      prevention = "synthetic prevention";
      removal = "synthetic removal";
      recovery = "synthetic recovery";
    };
  };
  qualification = import ./qualification;
  documentation = {
    page = "os/livepatches/synthetic";
    anchor = "release-6-12-113-1";
  };
}
