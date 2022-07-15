import ../../make-template.nix ({ distribution, version }: rec {
  instance = "${distribution}-${version}";

  test = pkgs: {
    name = "systemd-device-units@${instance}";

    description = ''
      Test that containers with ${distribution}-${version} have systemd device units
    '';

    machine = import ../../machines/tank.nix pkgs;

    testScript = ''
      machine.wait_for_osctl_pool("tank")
      machine.wait_until_online

      machine.all_succeed(
        "osctl ct new --distribution ${distribution} --version ${version} testct",
        "osctl ct unset start-menu testct",
        "osctl ct netif new routed testct eth0",
        "osctl ct start testct",
      )

      machine.wait_until_succeeds("osctl ct exec testct systemctl status sys-devices-virtual-net-eth0.device")

      machine.fails("osctl ct exec testct systemctl status sys-devices-virtual-net-dummy0.device")
      machine.succeeds("osctl ct exec testct ip link add dummy0 type dummy")
      machine.wait_until_succeeds("osctl ct exec testct systemctl status sys-devices-virtual-net-dummy0.device")
    '';
  };
})
