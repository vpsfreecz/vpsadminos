import ../../make-test.nix (
  { pkgs }:
  let
    common = import ./vpsadminos/common.nix { inherit pkgs; };
    loadavg = import ./vpsadminos/loadavg.nix { inherit pkgs common; };
  in
  {
    name = "kernel-loadavg";

    description = ''
      Test load average virtualization
    '';

    tags = [ "ci" ];
    testScriptJobs = 6;

    machines.cgv2 = common.mkMachine {
      cgroupsVersion = 2;
      extraConfig = loadavg.machineConfig;
    };

    testScripts = loadavg.testScripts;
  }
)
