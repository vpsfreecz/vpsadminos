import ../../../make-test.nix (
  { pkgs }:
  let
    common = import ../vpsadminos/common.nix { inherit pkgs; };
    scripts = import ../vpsadminos/cpu-view.nix { inherit common; };
  in
  {
    name = "kernel-cpu-view-cgroups-v2";

    description = ''
      Test CPU view virtualization with cgroups v2
    '';

    tags = [ "ci" ];
    testScriptJobs = 6;

    machines.cgv2 = common.mkMachine { cgroupsVersion = 2; };
    testScripts.cpu-view-cgroups-v2 = scripts.cpu-view-cgroups-v2;
  }
)
