import ../../make-test.nix (
  { pkgs }:
  import ./nfs-cancellation-common.nix {
    inherit pkgs;
    name = "osctl-nfs-cancellation";
    description = ''
      Hard NFS retry, forced container teardown and client isolation
    '';
    machine = import ../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config =
        { ... }:
        {
          # Default cancellation run: the .95 boot kernel plus livepatch_7,
          # which provides the terminal cancellation ABI under test.
          imports = [ ../../configs/vpsadminos/livepatch-6.12.95-boot-base.nix ];
          services.nfs.server.enable = true;
          osctl.exportfs.enable = true;
          services.live-patches.enable = true;
        };
    };
  }
)
