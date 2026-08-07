import ../../../make-test.nix (
  { pkgs }:
  let
    common = import ../vpsadminos/common.nix { inherit pkgs; };
    scripts = import ../vpsadminos/cpu-view.nix { inherit common; };
  in
  {
    name = "kernel-cpu-view-cgroups-v1";

    description = ''
      Test CPU view virtualization with cgroups v1
    '';

    tags = [ "ci" ];
    testScriptJobs = 6;

    machines.cgv1 = common.mkMachine { cgroupsVersion = 1; };
    testScripts.cpu-view-cgroups-v1 = scripts.cpu-view-cgroups-v1;
  }
)
