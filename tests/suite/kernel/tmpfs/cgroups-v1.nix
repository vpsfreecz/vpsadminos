import ../../../make-test.nix (
  { pkgs }:
  let
    common = import ../vpsadminos/common.nix { inherit pkgs; };
    scripts = import ../vpsadminos/tmpfs.nix { inherit common; };
  in
  {
    name = "kernel-tmpfs-cgroups-v1";

    description = ''
      Test container tmpfs behavior with cgroups v1
    '';

    tags = [ "ci" ];
    testScriptJobs = 6;

    machines.cgv1 = common.mkMachine { cgroupsVersion = 1; };
    testScripts.tmpfs-cgroups-v1 = scripts.tmpfs-cgroups-v1;
  }
)
