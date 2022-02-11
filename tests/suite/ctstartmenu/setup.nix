import ../../make-test.nix (pkgs: {
  name = "ctstartmenu-setup";

  description = ''
    Test container start menu integration
  '';

  machine = import ../../machines/tank.nix pkgs;

  testScript = ''
    machine.wait_for_osctl_pool("tank")
    machine.wait_until_online

    ip = "1.2.3.4"

    machine.all_succeed(
      "osctl ct new --distribution alpine testct",
      "osctl ct netif new routed testct eth0",
      "osctl ct netif ip add testct eth0 #{ip}/32",
    )

    machine.fails("ping -c 1 #{ip}")

    # Enabled by default
    _, output = machine.succeeds("osctl ct show -H -o start_menu testct")

    if output.strip != "true"
      fail "start menu is not enabled by default, output is #{output.inspect}"
    end

    _, output = machine.succeeds("osctl ct show -H -o start_menu_timeout testct")

    if output.strip != "5"
      fail "expected the default timeout to be 5, got #{output.inspect}"
    end

    # Find LXC config path
    _, output = machine.succeeds("osctl ct show -H -o lxc_dir testct")
    lxc_config = File.join(output.strip, "config")

    # Check the init command
    machine.succeeds("grep -q 'lxc.init.cmd = /dev/.osctl-mount-helper/ctstartmenu -timeout 5 /sbin/init' #{lxc_config}")

    # Start the VPS
    machine.succeeds("osctl ct start testct")

    # Check it booted
    machine.wait_until_succeeds("ping -c 1 #{ip}", timeout: 15)

    # Disable the start menu
    machine.succeeds("osctl ct unset start-menu testct")

    _, output = machine.succeeds("osctl ct show -H -o start_menu testct")

    if output.strip != "-"
      fail "unable to disable the start menu, output is #{output.inspect}"
    end

    # Verify the init command has been reset
    machine.succeeds("grep -q 'lxc.init.cmd = /sbin/init' #{lxc_config}")

    # Restart the VPS
    machine.succeeds("osctl ct restart testct")

    # Check it booted
    machine.wait_until_succeeds("ping -c 1 #{ip}", timeout: 15)

    # Reenable the start menu
    machine.succeeds("osctl ct set start-menu testct")

    _, output = machine.succeeds("osctl ct show -H -o start_menu testct")

    if output.strip != "true"
      fail "unable to enable the start menu, output is #{output.inspect}"
    end

    # Check the init command
    machine.succeeds("grep -q 'lxc.init.cmd = /dev/.osctl-mount-helper/ctstartmenu -timeout 5 /sbin/init' #{lxc_config}")

    # Change timeout
    machine.succeeds("osctl ct set start-menu --timeout 10 testct")

    _, output = machine.succeeds("osctl ct show -H -o start_menu_timeout testct")

    if output.strip != "10"
      fail "expected the default timeout to be 10, got #{output.inspect}"
    end

    machine.succeeds("grep -q 'lxc.init.cmd = /dev/.osctl-mount-helper/ctstartmenu -timeout 10 /sbin/init' #{lxc_config}")
  '';
})
