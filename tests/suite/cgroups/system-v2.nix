import ../../make-test.nix (
  { pkgs }:
  {
    name = "cgroups-system-v2";

    description = ''
      Test cgroupv2 configuration
    '';

    tags = [ "ci" ];

    machines = {
      # We expect the default to be cgroupv2
      default_cgroup = import ../../machines/vpsadminos/empty.nix pkgs;

      # We set the default to cgroupv1, but expect it to start with cgroupv2
      runtime_cgroup = import ../../machines/vpsadminos/with-empty.nix {
        inherit pkgs;
        config =
          { config, ... }:
          {
            boot.enableUnifiedCgroupHierarchy = false;
          };
      };
    };

    testScript = ''
      default_cgroup.start
      runtime_cgroup.start(kernel_params: ['osctl.cgroupv=2'])

      machines.each do |name, machine|
        machine.wait_for_boot(timeout: 20 * 60)

        _, output = machine.succeeds('cat /run/osctl/cgroup.version')
        if output.strip != "2"
          fail "expected cgroup version on #{name} to be 2, got '#{output.inspect}'"
        end

        machine.all_succeed(
          'cat /sys/fs/cgroup/cgroup.procs',
        )
      end
    '';
  }
)
