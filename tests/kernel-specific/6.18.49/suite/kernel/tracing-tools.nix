args:
import ../../../../suite/kernel/tracing-tools.nix (
  args
  // {
    modules = (args.modules or [ ]) ++ [
      ({ lib, ... }: {
        boot.kernelVersion = lib.mkForce "6.18.49";
      })
    ];
  }
)
