import ../../make-template.nix ({ distribution, version }: rec {
  instance = "${distribution}-${version}";

  test = pkgs: {
    name = "dist-config-netif-routed@${instance}";

    description = ''
      Test that routed network interface works with ${distribution}-${version}
    '';

    machine = import ../../machines/tank.nix pkgs;

    testScript = ''
      machine.wait_for_osctl_pool("tank")
      machine.wait_until_online

      ip = "1.2.3.4"

      machine.fails("ping -c 1 #{ip}")

      machine.all_succeed(
        "osctl ct new --distribution ${distribution} --version ${version} testct",
        "osctl ct netif new routed testct eth0",
        "osctl ct netif ip add testct eth0 #{ip}/32",
        "osctl ct start testct",
      )

      machine.wait_until_succeeds("ping -c 1 #{ip}")
    '';
  };
})
