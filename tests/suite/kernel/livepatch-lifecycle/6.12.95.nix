{
  bootModule = ../../../configs/vpsadminos/livepatch-6.12.95-boot-base.nix;

  # CI consumes exact released predecessor bytes from test fixtures, not
  # host-specific store paths or a rebuild from today's kernel sources.
  predecessors = {
    amd = {
      moduleName = "livepatch_5";
      version = 5;
      sha256 = "b31f64403d9d55f62e3d59e4bbefcbddcbda4fa66a2dc0689f9bb7cd7e927984";
      fixture = "releasedV5";
    };

    intel = {
      moduleName = "livepatch_5";
      version = 5;
      sha256 = "b31f64403d9d55f62e3d59e4bbefcbddcbda4fa66a2dc0689f9bb7cd7e927984";
      fixture = "releasedV5";
    };
  };

  # Exact shipped-v6 predecessor for the independent v6 -> v7 instance.
  predecessorsV6 = {
    amd = {
      moduleName = "livepatch_6";
      version = 6;
      sha256 = "960b13f1b461b95e29cccff58ddf0d3f3badf151046eb46eba36a9c8c7e5efe3";
      fixture = "shippedV6";
    };

    intel = {
      moduleName = "livepatch_6";
      version = 6;
      sha256 = "960b13f1b461b95e29cccff58ddf0d3f3badf151046eb46eba36a9c8c7e5efe3";
      fixture = "shippedV6";
    };
  };
}
