import ../../make-test.nix (
  { pkgs }:
  let
    availableKernels = import ../../../os/packages/linux/available-kernels.nix {
      inherit (pkgs) lib;
    };
    inherit (availableKernels) stableKernelVersion;
    stableKernel = availableKernels.kernels.${stableKernelVersion};
  in
  import ./nfs-cancellation-common.nix {
    inherit pkgs;
    name = "osctl-nfs-cancellation";
    description = ''
      Stable-kernel NFS cancellation, teardown lifetime and client isolation
    '';
    expectedKernelRelease = stableKernelVersion;
    expectedKernelRevision = stableKernel.rev;
    machine = import ../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config =
        { lib, ... }:
        {
          boot.kernelVersion = lib.mkForce stableKernelVersion;
          services.nfs.server.enable = true;
          osctl.exportfs.enable = true;
          services.live-patches.enable = false;
        };
    };
  }
)
