import ../../make-test.nix (pkgs: {
  name = "osctl-ct-mounts";

  description = ''
    Test that mounts can be added to containers
  '';

  machine = import ../../machines/tank.nix pkgs;

  testScript = ''
    machine.start
    machine.wait_for_osctl_pool("tank")
    machine.wait_until_online

    # Prepare datasets and a container
    machine.all_succeed(
      "zfs create -p tank/test/stopped",
      "zfs create -p tank/test/started",
      "echo stopped > /tank/test/stopped/stopped.txt",
      "echo started > /tank/test/started/started.txt",
      "osctl ct new --distribution alpine testct",
      "osctl ct unset start-menu testct",
      "osctl ct start testct",
    )

    # Ensure nothing exists before the mounts are created
    machine.all_fail(
      "osctl ct exec testct ls /mnt/stopped",
      "osctl ct exec testct ls /mnt/started",
    )

    # Configure mount on a stopped container
    machine.all_succeed(
      "osctl ct stop testct",
      "osctl ct mounts new --fs /tank/test/stopped --type bind --opts bind,create=dir --mountpoint /mnt/stopped testct",
      "osctl ct start testct",
    )

    _, output = machine.succeeds("osctl ct exec testct cat /mnt/stopped/stopped.txt")

    if output.strip != "stopped"
      fail "invalid mount: expected 'stopped', got #{output.inspect}"
    end

    machine.fails("osctl ct exec testct cat /mnt/started/started.txt")

    # Configure mount on a started container
    machine.succeeds("osctl ct mounts new --fs /tank/test/started --type bind --opts bind,create=dir --mountpoint /mnt/started testct")

    _, output = machine.succeeds("osctl ct exec testct cat /mnt/started/started.txt")

    if output.strip != "started"
      fail "invalid mount: expected 'started', got #{output.inspect}"
    end
  '';
})
