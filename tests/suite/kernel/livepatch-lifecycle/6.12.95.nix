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
      osRevision = "97a8c8fc64b1ef6339bca9e85a8ccdd6884cb3e0";
      version = 6;
      sha256 = "960b13f1b461b95e29cccff58ddf0d3f3badf151046eb46eba36a9c8c7e5efe3";
    };

    intel = mkPredecessor {
      osRevision = "97a8c8fc64b1ef6339bca9e85a8ccdd6884cb3e0";
      version = 6;
      sha256 = "960b13f1b461b95e29cccff58ddf0d3f3badf151046eb46eba36a9c8c7e5efe3";
    };
  };
}
