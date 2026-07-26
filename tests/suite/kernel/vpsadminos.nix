import ../../make-test.nix (
  { pkgs }:
  let
    common = import ./vpsadminos/common.nix { inherit pkgs; };
    loadavg = import ./vpsadminos/loadavg.nix { inherit pkgs common; };
    legacySource = pkgs.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "vpsadminos";
      rev = "fc6c9fe67d7d365f26a5ab286625fd55fd5f79e1";
      hash = "sha256-NGEgkL1PyYCtOijWTdvzA/FpCF1xRz6S1GtVEwaLseY=";
    };
    testScripts =
      (import ./vpsadminos/cpu-view.nix { inherit common; })
      // loadavg.testScripts
      // (import ./vpsadminos/memory-view.nix { inherit common; })
      // (import ./vpsadminos/misc.nix { inherit common; })
      // (import ./vpsadminos/syslogns.nix { inherit common; })
      // (import ./vpsadminos/tmpfs.nix { inherit common; })
      // (import ./vpsadminos/uptime.nix { inherit common; });
  in
  {
    name = "kernel-vpsadminos";

    description = ''
      Test vpsAdminOS kernel customizations
    '';

    tags = [ "ci" ];

    testScriptJobs = 6;

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
      cgv2 = common.mkMachine {
        cgroupsVersion = 2;
        extraConfig = loadavg.machineConfig;
      };
    };

    inherit testScripts;
  }
)
