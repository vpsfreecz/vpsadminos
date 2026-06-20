import ../../make-test.nix (
  { pkgs, distributions }:
  {
    name = "cgroups-mount-v2-on-v1";

    description = ''
      Test cgroupv2 controllers are mounted in containers on host with cgroups v1

      Since v1 controllers are in use, no v2 controllers are available.
      systemd since v258 dropped support for cgroups v1 and always mounts v2 in this
      way.
    '';

    tags = [ "ci" ];

    testScriptJobs = 5;

    machine = import ../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config =
        { config, ... }:
        {
          boot.enableUnifiedCgroupHierarchy = false;
        };
    };

    testScripts = builtins.listToAttrs (
      map (
        { distribution, version }:
        {
          name = "${distribution}-${version}";
          value = {
            script = ''
              machine.wait_for_osctl_pool("tank")
              machine.wait_until_online

              testct = get_container_id

              machine.all_succeed(
                "osctl ct new --distribution ${distribution} --version ${version} #{testct}",
                "osctl ct unset start-menu #{testct}",
                "osctl ct start #{testct}",
              )

              ${pkgs.lib.optionalString (distribution == "nixos") ''
                # LXC RUNNING precedes NixOS stage-2 activation. Require PID 1
                # to finish startup before checking the cgroup mounts.
                machine.wait_until_succeeds(
                  "osctl ct exec #{testct} systemctl is-system-running",
                  timeout: 180,
                )
              ''}

              # Give the container some time to start, as cgroups are mounted by the init
              # system
              sleep(10)

              _, mounts = machine.succeeds("osctl ct exec #{testct} cat /proc/mounts")

              # On a cgroups v1 host LXC mounts a cgroup2 root on /sys/fs/cgroup and
              # then the legacy v1 layout over it, while a guest init that mounts
              # unified itself (systemd since v258) replaces that legacy layout. Only
              # the last entry for the path is what the container actually sees, so
              # matching the first would accept a mount that is shadowed.
              effective = mounts.lines.reverse.find do |line|
                fields = line.split
                fields.length >= 3 && fields[1] == "/sys/fs/cgroup"
              end

              if effective.nil?
                fail "No mount on /sys/fs/cgroup"
              end

              if effective.split[2] != "cgroup2"
                # The container kept the legacy layout, which is what a guest that
                # still supports cgroups v1 uses on a v1 host: there is no unified
                # hierarchy here, so the v1 controllers must be the mounted ones.
                machine.fails("osctl ct exec #{testct} cat /sys/fs/cgroup/cgroup.controllers")

                legacy_mounts = mounts.lines.select do |line|
                  fields = line.split
                  fields.length >= 3 &&
                    fields[1].start_with?("/sys/fs/cgroup/") &&
                    fields[2] == "cgroup"
                end

                if legacy_mounts.empty?
                  fail "Expected legacy cgroup mounts on a cgroups v1 host"
                end
              else
                _, output = machine.succeeds("osctl ct exec #{testct} cat /sys/fs/cgroup/cgroup.controllers")
                enabled_controllers = output.strip.split(" ")

                if enabled_controllers.any?
                  fail "Did not expect any controllers, got #{enabled_controllers.inspect}"
                end

                # A v2 child can use a controller name, so detect actual nested v1
                # mounts instead of checking whether controller-named paths exist.
                hybrid_mounts = mounts.lines.select do |line|
                  fields = line.split
                  fields.length >= 3 &&
                    fields[1].start_with?("/sys/fs/cgroup/") &&
                    fields[2] == "cgroup"
                end

                if hybrid_mounts.any?
                  fail "Unexpected hybrid cgroup mounts:\n#{hybrid_mounts.join}"
                end
              end

              machine.all_succeed(
                "osctl ct del -f --prune #{testct}",
                "osctl repository images prune"
              )
            '';
          };
        }
      ) distributions
    );
  }
)
