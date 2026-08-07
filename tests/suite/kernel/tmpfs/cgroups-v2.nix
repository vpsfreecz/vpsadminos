import ../../../make-test.nix (
  { pkgs }:
  let
    common = import ../vpsadminos/common.nix { inherit pkgs; };
    scripts = import ../vpsadminos/tmpfs.nix { inherit common; };
  in
  {
    name = "kernel-tmpfs-cgroups-v2";

    description = ''
      Test container tmpfs behavior with cgroups v2
    '';

    tags = [ "ci" ];
    testScriptJobs = 6;

    machines.cgv2 = common.mkMachine { cgroupsVersion = 2; };
    testScripts.tmpfs-cgroups-v2 = scripts.tmpfs-cgroups-v2;
  }
)
