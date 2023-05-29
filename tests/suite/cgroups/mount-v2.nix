import ../../make-template.nix ({ distribution, version }: rec {
  instance = "${distribution}-${version}";

  test = pkgs: {
    name = "cgroups-mount-v2@${instance}";

    description = ''
      Test cgroupv2 controllers are mounted in ${distribution}-${version} containers
    '';

    machine = import ../../machines/with-tank.nix {
      inherit pkgs;
      config =
        { config, ... }:
        {
          boot.enableUnifiedCgroupHierarchy = true;
        };
    };

    testScript = ''
      machine.wait_for_osctl_pool("tank")
      machine.wait_until_online

      machine.all_succeed(
        "osctl ct new --distribution ${distribution} --version ${version} testct",
        "osctl ct unset start-menu testct",
        "osctl ct start testct",
      )

      # Give the container some time to start, as cgroups are mounted by the init
      # system
      sleep(10)

      _, output = machine.succeeds("osctl ct exec testct cat /proc/mounts")

      if /^\w+ #{Regexp.escape("/sys/fs/cgroup cgroup2 ")}/ !~ output
        fail "unified cgroup not mounted"
      end

      _, output = machine.succeeds("osctl ct exec testct cat /sys/fs/cgroup/cgroup.controllers")
      enabled_controllers = output.strip.split(" ")
      expected_controllers = %w(cpuset cpu io memory hugetlb pids rdma)

      expected_controllers.each do |v|
        unless enabled_controllers.include?(v)
          fail "controller '#{v}' not enabled on /sys/fs/cgroup"
        end
      end

      # Check that the system does not try to use the unified cgroup as if it
      # was a hybrid hierarchy
      hybrid_controllers = %w(
        blkio
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
        machine.fails("osctl ct exec testct ls /sys/fs/cgroup/#{v}")
      end
    '';
  };
})
