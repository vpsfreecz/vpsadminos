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
  # The candidate comes from the current tree and its locked kernel/toolchain
  # inputs, so its raw module checksum legitimately changes with dependency
  # updates. Historical predecessors are evaluated from immutable revisions
  # and remain checksummed to ensure that the intended shipped bytes are used.
  predecessors = {
    amd = mkPredecessor {
      osRevision = "02dfcc956bff56a2fb3dbce734dba259b9dfb123";
      version = 4;
      sha256 = "faa3d5a4d7e8db0d97eeb362e9e7e7400139e575c58a56f92573bd7a88c0c811";
    };

    intel = mkPredecessor {
      osRevision = "02dfcc956bff56a2fb3dbce734dba259b9dfb123";
      version = 4;
      sha256 = "faa3d5a4d7e8db0d97eeb362e9e7e7400139e575c58a56f92573bd7a88c0c811";
    };
  };
}
