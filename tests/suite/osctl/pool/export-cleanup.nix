import ../../../make-test.nix (pkgs: {
  name = "osctl-pool-export-cleanup";

  description = ''
    Test that users/groups/containers are removed on pool export
  '';

  machine = import ../../../machines/tank.nix pkgs;

  testScript = ''
    machine.start
    machine.wait_for_osctl_pool("tank")
    machine.wait_until_online

    # Start a container
    machine.all_succeed(
      "osctl ct new --distribution alpine testct",
      "osctl ct start testct",
    )

    # Check user/group/ct exist
    machine.all_succeed(
      "osctl user show testct",
      "id tank-testct",
      "osctl group show /default",
      "osctl ct show testct",
      "ls -l /run/osctl/lxcfs/runsvdir/ct.tank:testct",
    )

    # Export must fail, because of running containers
    machine.fails("osctl pool export tank")

    # Check user/group/ct still exist
    machine.all_succeed(
      "osctl user show testct",
      "id tank-testct",
      "osctl group show /default",
      "osctl ct show testct",
    )

    # Forceful export
    machine.succeeds("osctl pool export -f tank")

    # Check all user/group/ct are removed
    machine.all_fail(
      "osctl user show testct",
      "id tank-testct",
      "osctl group show /default",
      "osctl ct show testct",
      "ls -l /run/osctl/lxcfs/runsvdir/ct.tank:testct",
      "ls -l /run/osctl/lxcfs/servers/ct.tank:testct",
    )
  '';
})
