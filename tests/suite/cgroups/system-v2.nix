import ../../make-test.nix (pkgs: {
  name = "cgroups-v2";

  description = ''
    Test cgroupv2 configuration
  '';

  machines = {
    # Enable cgroupv2 by default
    config_cgroup = import ../../machines/with-empty.nix {
      inherit pkgs;
      config =
        { config, ... }:
        {
          boot.enableUnifiedCgroupHierarchy = true;
        };
    };

    # We set the default to cgroupv1, but expect it to start with cgroupv2
    runtime_cgroup = import ../../machines/with-empty.nix {
      inherit pkgs;
      config =
        { config, ... }:
        {
          boot.enableUnifiedCgroupHierarchy = false;
        };
    };
  };

  testScript = ''
    config_cgroup.start
    runtime_cgroup.start(kernel_params: ['osctl.cgroupv=2'])

    machines.each do |name, machine|
      _, output = machine.succeeds('cat /run/osctl/cgroup.version')
      if output.strip != "2"
        fail "expected cgroup version on #{name} to be 2, got '#{output.inspect}'"
      end

      machine.all_succeed(
        'cat /sys/fs/cgroup/cgroup.procs',
      )
    end
  '';
})
