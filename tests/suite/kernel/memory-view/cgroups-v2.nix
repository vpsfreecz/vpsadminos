import ../../../make-test.nix (
  { pkgs }:
  let
    common = import ../vpsadminos/common.nix { inherit pkgs; };
    scripts = import ../vpsadminos/memory-view.nix { inherit common; };
  in
  {
    name = "kernel-memory-view-cgroups-v2";

    description = ''
      Test memory view virtualization with cgroups v2
    '';

    tags = [ "ci" ];
    testScriptJobs = 6;

    machines.cgv2 = common.mkMachine { cgroupsVersion = 2; };
    testScripts.memory-view-cgroups-v2 = scripts.memory-view-cgroups-v2;
  }
)
