import ../../make-test.nix (
  { pkgs }:
  let
    common = import ./vpsadminos/common.nix { inherit pkgs; };
  in
  {
    name = "kernel-syslogns";

    description = ''
      Test syslog namespace behavior
    '';

    tags = [ "ci" ];
    testScriptJobs = 6;

    machines.cgv2 = common.mkMachine { cgroupsVersion = 2; };
    testScripts = import ./vpsadminos/syslogns.nix { inherit common; };
  }
)
