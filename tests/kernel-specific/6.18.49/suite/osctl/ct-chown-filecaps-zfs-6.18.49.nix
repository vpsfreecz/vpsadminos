args:
import ../../../../suite/osctl/ct-chown-filecaps.nix (
  args
  // {
    modules = (args.modules or [ ]) ++ [
      ({ lib, ... }: {
        boot.kernelVersion = lib.mkForce "6.18.49";
      })
    ];
    testArgs = {
      modes = [ "zfs" ];
      testName = "osctl-ct-chown-filecaps-zfs-6.18.49";
    };
  }
)
