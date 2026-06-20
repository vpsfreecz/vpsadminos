import ../../make-test.nix (
  { pkgs, distributions }:
  {
    name = "cgroups-mount-v2";

    description = ''
      Test cgroupv2 controllers are mounted in containers
    '';

    tags = [ "ci" ];

    testScriptJobs = 5;

    machine = import ../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config =
        { config, ... }:
        {
          boot.enableUnifiedCgroupHierarchy = true;
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

              _, mounts = machine.succeeds("osctl ct exec #{testct} cat /proc/mounts")

              if /^\w+ #{Regexp.escape("/sys/fs/cgroup cgroup2 ")}/ !~ mounts
                fail "unified cgroup not mounted"
              end

              _, output = machine.succeeds("osctl ct exec #{testct} cat /sys/fs/cgroup/cgroup.controllers")
              enabled_controllers = output.strip.split(" ")
              expected_controllers = %w(cpuset cpu memory hugetlb pids rdma)

              expected_controllers.each do |v|
                unless enabled_controllers.include?(v)
                  fail "controller '#{v}' not enabled on /sys/fs/cgroup"
                end
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
