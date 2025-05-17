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

        if [ "${distribution}" == "alpine" ] || [ "${distribution}" == "chimera" ]; then
          grep -q /run /proc/mounts || fail "/run not found in /proc/mounts"
        else
          grep -q /run /proc/mounts && fail "/run found in /proc/mounts"
        fi

        exit 0
      '';
    in {
      name = "dist-config-nonsystemd-rundir@${instance}";

      description =
        if distribution == "alpine" || distribution == "chimera" then ''
          Test that containers with ${distribution}-${version} have /run pre-mounted
          before the init is started as configured
          in osctld/configs/lxc/${distribution}/common.conf.
        '' else  ''
          Test that containers with ${distribution}-${version} do not have /run
          pre-mounted before the init is started.
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
