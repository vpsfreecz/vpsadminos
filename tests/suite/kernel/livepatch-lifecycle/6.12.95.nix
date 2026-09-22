let
  v5AnchorEnv = builtins.getEnv "VPSADMINOS_LIVEPATCH_RELEASED_V5_MODULE";
  v6AnchorEnv = builtins.getEnv "VPSADMINOS_LIVEPATCH_PREDECESSOR_MODULE";
in
assert v5AnchorEnv != "";
let
  # The exact v5/v6 predecessors are supplied as store paths (the same inputs
  # the payload suite binds) and pinned by sha256: the production bytes are not
  # reproducible by evaluating an OS revision, so the predecessor is the exact
  # module file rather than a rebuilt one. The lifecycle script selects the set
  # with VPSADMINOS_LIVEPATCH_PREDECESSOR_VARIANT (v5 default, v6 exact).
  v5Anchor = builtins.storePath v5AnchorEnv;
  v6Anchor = builtins.storePath v6AnchorEnv;
in
{
  bootModule = ../../../configs/vpsadminos/livepatch-6.12.95-boot-base.nix;

  predecessors = {
    amd = {
      moduleName = "livepatch_5";
      version = 5;
      sha256 = "b31f64403d9d55f62e3d59e4bbefcbddcbda4fa66a2dc0689f9bb7cd7e927984";
      module = v5Anchor;
    };

    intel = {
      moduleName = "livepatch_5";
      version = 5;
      sha256 = "b31f64403d9d55f62e3d59e4bbefcbddcbda4fa66a2dc0689f9bb7cd7e927984";
      module = v5Anchor;
    };
  };

  # Exact shipped-v6 predecessor set for the v6 -> v7 lifecycle path; selected
  # with VPSADMINOS_LIVEPATCH_PREDECESSOR_VARIANT=v6 (default v5).
  predecessorsV6 = {
    amd = {
      moduleName = "livepatch_6";
      version = 6;
      sha256 = "960b13f1b461b95e29cccff58ddf0d3f3badf151046eb46eba36a9c8c7e5efe3";
      module = v6Anchor;
    };

    intel = {
      moduleName = "livepatch_6";
      version = 6;
      sha256 = "960b13f1b461b95e29cccff58ddf0d3f3badf151046eb46eba36a9c8c7e5efe3";
      module = v6Anchor;
    };
  };
}
