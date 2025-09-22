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

    machine = import ../../machines/with-tank.nix {
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

              # Give the container some time to start, as cgroups are mounted by the init
              # system
              sleep(10)

              _, output = machine.succeeds("osctl ct exec #{testct} cat /proc/mounts")

              if /^\w+ #{Regexp.escape("/sys/fs/cgroup cgroup2 ")}/ !~ output
                fail "unified cgroup not mounted"
              end

              _, output = machine.succeeds("osctl ct exec #{testct} cat /sys/fs/cgroup/cgroup.controllers")
              enabled_controllers = output.strip.split(" ")

              if enabled_controllers.any?
                fail "Did not expect any controllers, got #{enabled_controllers.inspect}"
              end

              # Check that the system does not try to use the unified cgroup as if it
              # was a hybrid hierarchy
              hybrid_controllers = %w(
                cpu,cpuacct
                cpuset
                devices
                freezer
                hugetlb
                memory
                net_cls,net_prio
                perf_event
                pids
                rdma
                systemd
              )

              hybrid_controllers.each do |v|
                machine.fails("osctl ct exec #{testct} ls /sys/fs/cgroup/#{v}")
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
