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
      osRevision = "1895bbcdd21d0c71e6e7ee442739c4b5190ce5e7";
      version = 5;
      sha256 = "f09ac45ab38929273f857e62f7bd04aaf9256dfbbf1eb64f39249611dd9a1255";
    };

    intel = mkPredecessor {
      osRevision = "1895bbcdd21d0c71e6e7ee442739c4b5190ce5e7";
      version = 5;
      sha256 = "f09ac45ab38929273f857e62f7bd04aaf9256dfbbf1eb64f39249611dd9a1255";
    };
  };
}
