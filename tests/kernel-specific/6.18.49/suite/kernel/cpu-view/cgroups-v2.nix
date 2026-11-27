args:
import ../../../../../suite/kernel/cpu-view/cgroups-v2.nix (
  args
  // {
    modules = (args.modules or [ ]) ++ [
      ({ lib, ... }: {
        boot.kernelVersion = lib.mkForce "6.18.49";
      })
    ];
  }
)
