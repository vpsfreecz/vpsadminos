import ../../make-test.nix (
  { pkgs }:
  let
    common = import ./vpsadminos/common.nix { inherit pkgs; };
  in
  {
    name = "kernel-uptime";

    description = ''
      Test container uptime virtualization
    '';

    tags = [ "ci" ];
    testScriptJobs = 6;

    machines.cgv2 = common.mkMachine { cgroupsVersion = 2; };
    testScripts = import ./vpsadminos/uptime.nix { inherit common; };
  }
)
