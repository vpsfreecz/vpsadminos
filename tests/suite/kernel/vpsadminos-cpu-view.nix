import ../../make-test.nix (
  { pkgs }:
  let
    common = import ./vpsadminos/common.nix { inherit pkgs; };
    legacySource = pkgs.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "vpsadminos";
      rev = "fc6c9fe67d7d365f26a5ab286625fd55fd5f79e1";
      hash = "sha256-NGEgkL1PyYCtOijWTdvzA/FpCF1xRz6S1GtVEwaLseY=";
    };
  in
  {
    name = "kernel-vpsadminos-cpu-view";

    description = ''
      Test vpsAdminOS CPU view and lifecycle policy reconstruction
    '';

    tags = [ "ci" ];

    testScriptJobs = 2;

    machines = {
      cgv1 = common.mkMachine {
        cgroupsVersion = 1;
        extraConfig =
          { pkgs, ... }:
          let
            legacyOsctld = pkgs.writeShellScriptBin "legacy-osctld" ''
              export RUBYLIB="${legacySource}/osctld/lib:${legacySource}/libosctl/lib"
              exec ${pkgs.osctld}/bin/osctld "$@"
            '';
          in
          {
            environment.systemPackages = [ legacyOsctld ];
          };
      };
      cgv2 = common.mkMachine { cgroupsVersion = 2; };
    };

    testScripts = import ./vpsadminos/cpu-view.nix { inherit common; };
  }
)
