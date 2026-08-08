let
  mkPredecessor =
    {
      osRevision,
      version,
      sha256,
    }:
    let
      previousOs = builtins.getFlake "github:vpsfreecz/vpsadminos/${osRevision}";
      evaluated = previousOs.lib.vpsadminosSystem {
        system = "x86_64-linux";
        modules = [
          {
            boot.kernelVersion = "6.12.95";
            services.live-patches.enable = true;
          }
        ];
      };
      package = evaluated.config.system.build.livePatches;
      moduleName = "livepatch_${toString version}";
    in
    {
      inherit
        moduleName
        osRevision
        sha256
        version
        ;
      module = "${package}/lib/modules/6.12.95/extra/${moduleName}.ko";
    };
in
{
  candidateSha256 = "faa3d5a4d7e8db0d97eeb362e9e7e7400139e575c58a56f92573bd7a88c0c811";

  predecessors = {
    # Shipped v3 can wedge while activating its Safe-RET transition on the
    # affected AMD host, so v4 must be tested there from the latest safe v2.
    amd = mkPredecessor {
      osRevision = "008aa4605ec263397bf46bd9fe915a01be1670a6";
      version = 2;
      sha256 = "88e7aede28426a8f9d628cc6675f3b79e0df13865e1e8a2c78f528163709b1ae";
    };

    intel = mkPredecessor {
      osRevision = "d1d73edcdc574e6bccd06e37c6bf2f80393a5771";
      version = 3;
      sha256 = "2295e328a72732765a276ba731929f507aefac7922ae19cf1f8f967e81018817";
    };
  };
}
