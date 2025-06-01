import ../../make-test.nix ({pkgs, distributions }: {
name = "systemd-device-units";

description = ''
  Test that containers have systemd device units
'';

tags = [ "ci" ];

machine = import ../../machines/tank.nix pkgs;

testScripts = builtins.listToAttrs (map ({ distribution, version }: {
    name = "${distribution}-${version}";
    value = {
      # These distributions do have the device unit, but it is inactive (dead) and so
      # systemctl status returns non-zero exit status.
      expectFailure = (distribution == "opensuse" && version == "latest");

      script = ''
        machine.wait_for_osctl_pool("tank")
        machine.wait_until_online

        testct = get_container_id

        machine.all_succeed(
          "osctl ct new --distribution ${distribution} --version ${version} #{testct}",
          "osctl ct unset start-menu #{testct}",
          "osctl ct netif new routed #{testct} eth0",
          "osctl ct start #{testct}",
        )

        machine.wait_until_succeeds(
          "osctl ct exec #{testct} systemctl status sys-devices-virtual-net-eth0.device",
          timeout: 60
        )

        machine.fails("osctl ct exec #{testct} systemctl status sys-devices-virtual-net-dummy0.device")
        machine.succeeds("osctl ct exec #{testct} ip link add dummy0 type dummy")
        machine.wait_until_succeeds(
          "osctl ct exec #{testct} systemctl status sys-devices-virtual-net-dummy0.device",
          timeout: 60
        )
        machine.succeeds("osctl ct del -f --prune #{testct}")
      '';
    };
  }) distributions);
})
