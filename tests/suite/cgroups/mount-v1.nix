import ../../make-template.nix ({ distribution, version }: rec {
  instance = "${distribution}-${version}";

  test = pkgs: {
    name = "cgroups-mount-v1@${instance}";

    description = ''
      Test cgroupv1 controllers are mounted in ${distribution}-${version} containers
    '';

    machine = import ../../machines/tank.nix pkgs;

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

      controllers = %w(
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

      controllers.each do |c|
        if /^\w+ #{Regexp.escape("/sys/fs/cgroup/#{c} cgroup ")}/ !~ output
          fail "#{c} not mounted"
        end
      end

      # unified cgroup is not mounted on CentOS 7 and 8
      check_unified =
        if ("${distribution}" == "centos" && %w(7 latest-8-stream).include?("${version}")) \
           || ("${distribution}" == "almalinux" && "${version}" == "8")
          false
        else
          true
        end

      if check_unified && /^\w+ #{Regexp.escape("/sys/fs/cgroup/unified cgroup2 ")}/ !~ output
        fail "unified cgroup not mounted"
      end
    '';
  };
})
