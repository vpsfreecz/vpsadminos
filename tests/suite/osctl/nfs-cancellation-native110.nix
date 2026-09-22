import ../../make-test.nix (
  { pkgs }:
  import ./nfs-cancellation-common.nix {
    inherit pkgs;
    name = "osctl-nfs-cancellation-native110";
    description = ''
      Native 6.12.110 NFS cancellation continuity (A11 case 13/F): the same
      examples against the native .110 candidate, where the ABI is built in and
      no livepatch is present.
    '';
    machine = import ../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config =
        { ... }:
        {
          imports = [ ../../configs/vpsadminos/livepatch-6.12.110-native.nix ];
          services.nfs.server.enable = true;
          osctl.exportfs.enable = true;
          services.live-patches.enable = false;
        };
    };
  }
)
