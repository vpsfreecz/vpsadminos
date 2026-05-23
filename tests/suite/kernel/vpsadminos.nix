import ../../make-test.nix (
  { pkgs }:
  let
    common = import ./vpsadminos/common.nix { inherit pkgs; };
    loadavg = import ./vpsadminos/loadavg.nix { inherit pkgs common; };

    testScripts =
      (import ./vpsadminos/cpu-view.nix { inherit common; })
      // loadavg.testScripts
      // (import ./vpsadminos/memory-view.nix { inherit common; })
      // (import ./vpsadminos/misc.nix { inherit common; })
      // (import ./vpsadminos/syslogns.nix { inherit common; })
      // (import ./vpsadminos/tmpfs.nix { inherit common; })
      // (import ./vpsadminos/uptime.nix { inherit common; });
  in
  {
    name = "kernel-vpsadminos";

    description = ''
      Test vpsAdminOS kernel customizations
    '';

    tags = [ "ci" ];

    testScriptJobs = 6;

    machines = {
      cgv1 = common.mkMachine { cgroupsVersion = 1; };
      cgv2 = common.mkMachine {
        cgroupsVersion = 2;
        extraConfig = loadavg.machineConfig;
      };
    };

    inherit testScripts;
  }
)
