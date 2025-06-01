import ../../make-test.nix ({ pkgs, distributions }: {
  name = "cgroups-mount-v1";

  description = ''
    Test cgroupv1 controllers are mounted in containers
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

  testScripts = builtins.listToAttrs (map ({ distribution, version }: {
    name = "${distribution}-${version}";
    value = {
      # Gentoo with musl/openrc has problems mounting joined cpu,cpuacct cgroup
      # and possibly others.
      expectFailure = distribution == "gentoo" && (version == "latest-openrc" || version == "latest-musl");

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

        controllers = %w(
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

        # unified cgroup is not mounted on CentOS/Alma/Rocky 7 and 8
        check_unified =
          if ("${distribution}" == "centos" && %w(7).include?("${version}")) \
              || ("${distribution}" == "almalinux" && "${version}" == "8") \
              || ("${distribution}" == "rocky" && "${version}" == "8")
            false
          else
            true
          end

        if check_unified && /^\w+ #{Regexp.escape("/sys/fs/cgroup/unified cgroup2 ")}/ !~ output
          fail "unified cgroup not mounted"
        end

        machine.succeeds("osctl ct del -f --prune #{testct}")
      '';
    };
  }) distributions);
})
