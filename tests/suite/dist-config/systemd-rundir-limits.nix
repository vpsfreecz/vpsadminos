import ../../make-test.nix (
  { pkgs }:
  {
    name = "dist-config-systemd-rundir-limits";

    description = ''
      Test that osctld-mounted /run in containers respects memory limits
    '';

    tags = [ "ci" ];

    machines = {
      cgv1 = import ../../machines/vpsadminos/with-tank.nix {
        inherit pkgs;
        config =
          { config, ... }:
          {
            boot.enableUnifiedCgroupHierarchy = false;
          };
      };

      cgv2 = import ../../machines/vpsadminos/with-tank.nix {
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

        testct = "#{name}-testct"
        parent_group = "/#{name}-rundir"
        child_group = "#{parent_group}/child"

        # We expect tmpfs size to be a half of the memory limit
        begin
          machine.all_succeed(
            "osctl group new -p #{child_group}",
            "osctl ct new --distribution arch #{testct}",
            "osctl ct chgrp #{testct} #{child_group}",

            # No limit, just expect /run to be tmpfs
            "osctl ct exec -r #{testct} df -t tmpfs --output=size /run",

            # Container limit
            "osctl ct set memory #{testct} 1G",
            "osctl ct exec -r #{testct} df -t tmpfs --output=size /run | grep 524288",
            "osctl ct unset memory #{testct}",

            # Group limit
            "osctl group set memory #{child_group} 512M",
            "osctl ct exec -r #{testct} df -t tmpfs --output=size /run | grep 262144",
            "osctl group unset memory #{child_group}",

            # Parent group limit
            "osctl group set memory #{parent_group} 1G",
            "osctl ct exec -r #{testct} df -t tmpfs --output=size /run | grep 524288",
            "osctl group unset memory #{parent_group}",
          )
        ensure
          machine.execute("osctl ct del -f --prune #{testct}", timeout: 300)
          machine.execute("osctl group del #{child_group}", timeout: 60)
          machine.execute("osctl group del #{parent_group}", timeout: 60)
        end

        machine.stop
      end
    '';
  }
)
