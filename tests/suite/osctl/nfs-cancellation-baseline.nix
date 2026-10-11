import ../../make-test.nix (
  { pkgs }:
  import ./nfs-cancellation-common.nix {
    inherit pkgs;
    name = "osctl-nfs-cancellation-baseline";
    description = "Unpatched .95: forced soft retry and absent cancellation ABI";
    baseline = true;
    machine = import ../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config =
        { lib, ... }:
        {
          imports = [ ../../configs/vpsadminos/livepatch-6.12.95-boot-base.nix ];
          services.nfs.server.enable = true;
          osctl.exportfs.enable = true;
          # An explicit machine option, never an environment-default override.
          services.live-patches.enable = lib.mkForce false;
        };
    };
  }
)
