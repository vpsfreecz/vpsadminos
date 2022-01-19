import ../../make-test.nix (pkgs: {
  name = "cgroups-v1";

  description = ''
    Test cgroupv1 configuration
  '';

  machines = {
    # We expect the default to be cgroupv1
    default_cgroup = import ../../machines/empty.nix pkgs;

    # We set the default to cgroupv2, but expect it to start with cgroupv1
    runtime_cgroup = import ../../machines/with-empty.nix {
      inherit pkgs;
      config =
        { config, ... }:
        {
          boot.enableUnifiedCgroupHierarchy = true;
        };
    };
  };

  testScript = ''
    default_cgroup.start
    runtime_cgroup.start(kernel_params: ['osctl.cgroupv=1'])

    machines.each do |name, machine|
      _, output = machine.succeeds('cat /run/osctl/cgroup.version')
      if output.strip != "1"
        fail "expected cgroup version on #{name} to be 1, got '#{output.inspect}'"
      end

      machine.all_succeed(
        'cat /sys/fs/cgroup/cpuset/cgroup.procs',
        'cat /sys/fs/cgroup/unified/cgroup.procs',
      )
    end
  '';
})
