import ../../make-template.nix ({ distribution, version }: rec {
  instance = "${distribution}-${version}";

  test = pkgs: {
    name = "dist-config-start-stop@${instance}";

    description = ''
      Test that containers with ${distribution}-${version} can be started/stopped
    '';

    machine = import ../../machines/tank.nix pkgs;

    testScript = ''
      machine.wait_for_osctl_pool("tank")
      machine.wait_until_online

      machine.all_succeed(
        "osctl ct new --distribution ${distribution} --version ${version} testct",
        "osctl ct start testct",
      )

      sleep(15)

      machine.succeeds("osctl ct stop --dont-kill testct")
    '';
  };
})
