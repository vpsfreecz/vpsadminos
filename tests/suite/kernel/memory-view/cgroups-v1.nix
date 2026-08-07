import ../../../make-test.nix (
  { pkgs }:
  let
    common = import ../vpsadminos/common.nix { inherit pkgs; };
    scripts = import ../vpsadminos/memory-view.nix { inherit common; };
  in
  {
    name = "kernel-memory-view-cgroups-v1";

    description = ''
      Test memory view virtualization with cgroups v1
    '';

    tags = [ "ci" ];
    testScriptJobs = 6;

    machines.cgv1 = common.mkMachine { cgroupsVersion = 1; };
    testScripts.memory-view-cgroups-v1 = scripts.memory-view-cgroups-v1;
  }
)
