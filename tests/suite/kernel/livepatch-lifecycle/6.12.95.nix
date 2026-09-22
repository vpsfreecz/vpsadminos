let
  v5AnchorEnv = builtins.getEnv "VPSADMINOS_LIVEPATCH_RELEASED_V5_MODULE";
in
assert v5AnchorEnv != "";
let
  # The exact production v5 anchor is supplied as a store path (the same
  # input the payload suite binds) and pinned by sha256: the production
  # bytes are not reproducible by evaluating an OS revision, so the
  # predecessor is the exact module file rather than a rebuilt one.
  v5Anchor = builtins.storePath v5AnchorEnv;
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
}
