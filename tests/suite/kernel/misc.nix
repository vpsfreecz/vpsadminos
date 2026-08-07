import ../../make-test.nix (
  { pkgs }:
  let
    common = import ./vpsadminos/common.nix { inherit pkgs; };
  in
  {
    name = "kernel-misc";

    description = ''
      Test miscellaneous vpsAdminOS kernel behavior
    '';

    tags = [ "ci" ];
    testScriptJobs = 6;

    machines.cgv2 = common.mkMachine { cgroupsVersion = 2; };
    testScripts = import ./vpsadminos/misc.nix { inherit common; };
  }
)
