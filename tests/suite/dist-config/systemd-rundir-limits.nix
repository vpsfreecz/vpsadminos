import ../../make-test.nix (pkgs: {
  name = "dist-config-systemd-rundir-limits";

  description = ''
    Test that osctld-mounted /run in containers respects memory limits
  '';

  machines = {
    cgv1 = import ../../machines/with-tank.nix {
      inherit pkgs;
      config =
        { config, ... }:
        {
          boot.enableUnifiedCgroupHierarchy = false;
        };
    };

    cgv2 = import ../../machines/with-tank.nix {
      inherit pkgs;
      config =
        { config, ... }:
        {
          boot.enableUnifiedCgroupHierarchy = true;
        };
    };
  };

  testScript = ''
    machines.each do |name, machine|
      machine.start
      machine.wait_for_osctl_pool("tank")
      machine.wait_until_online

      # We expect tmpfs size to be a half of the memory limit
      machine.all_succeed(
        "osctl ct new --distribution arch #{name}-testct",

        # No limit, just expect /run to be tmpfs
        "osctl ct exec -r #{name}-testct df -t tmpfs --output=size /run",

        # Container limit
        "osctl ct set memory #{name}-testct 1G",
        "osctl ct exec -r #{name}-testct df -t tmpfs --output=size /run | grep 524288",
        "osctl ct unset memory #{name}-testct",

        # Group limits
        "osctl group set memory /default 512M",
        "osctl ct exec -r #{name}-testct df -t tmpfs --output=size /run | grep 262144",
        "osctl group unset memory /default",

        "osctl group set memory / 1G",
        "osctl ct exec -r #{name}-testct df -t tmpfs --output=size /run | grep 524288",
      )

      machine.kill
    end
  '';
})
