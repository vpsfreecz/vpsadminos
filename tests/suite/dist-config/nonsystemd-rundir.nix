import ../../make-template.nix ({ distribution, version }: rec {
  instance = "${distribution}-${version}";

  test = pkgs:
    let
      runScript = pkgs.writeScript "dist-config-nonsystemd-rundir-script.sh" ''
        #!/bin/sh
        fail() {
          echo $@
          exit 1
        }

        grep -q /run /proc/mounts || fail "/run found in /proc/mounts"

        exit 0
      '';
    in {
      name = "dist-config-nonsystemd-rundir@${instance}";

      description = ''
        Test that containers with ${distribution}-${version} do not have /run
        pre-mounted before the init is started
      '';

      machine = import ../../machines/tank.nix pkgs;

      testScript = ''
        machine.wait_for_osctl_pool("tank")
        machine.wait_until_online

        machine.succeeds(
          "osctl ct new --distribution ${distribution} --version ${version} testct",
        )
        machine.push_file("${runScript}", "/tmp/test-script.sh")
        machine.succeeds("osctl ct runscript -r testct /tmp/test-script.sh")
      '';
    };
})
