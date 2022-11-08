import ../../make-template.nix ({ distribution, version }: rec {
  instance = "${distribution}-${version}";

  test = pkgs: {
    name = "lxcfs-overlays@${instance}";

    description = ''
      Test LXCFS is mounted in containers with ${distribution}-${version}
    '';

    machine = import ../../machines/with-tank.nix {
      inherit pkgs;
      config =
        { config, ... }:
        {
          services.lxcfs.enable = false;
        };
    };

    testScript = ''
      be_mounted = %w(
        /proc/cpuinfo
        /proc/diskstats
        /proc/loadavg
        /proc/stat
        /proc/uptime
        /var/lib/lxcfs
      )

      be_unmounted = %w(
        /proc/meminfo
        /proc/swaps
        /sys/devices/system/cpu/online
      )

      check_mounted = Proc.new do |output|
        be_mounted.each do |f|
          if /^lxcfs #{Regexp.escape(f)} fuse\.lxcfs / !~ output
            fail "#{f} not mounted"
          end
        end

        be_unmounted.each do |f|
          if /^lxcfs #{Regexp.escape(f)} fuse\.lxcfs / =~ output
            fail "#{f} mounted"
          end
        end
      end

      machine.wait_for_osctl_pool("tank")
      machine.wait_until_online

      # LXCFS is enabled by default
      machine.all_succeed(
        "osctl ct new --distribution ${distribution} --version ${version} testct",
        "osctl ct exec -r testct mkdir -p /var/lib/lxcfs",
      )

      # Test exec and runscript
      _, output = machine.succeeds("osctl ct exec -r testct cat /proc/mounts")
      check_mounted.call(output)

      _, output = machine.succeeds("echo cat /proc/mounts | osctl ct runscript -r testct -")
      check_mounted.call(output)

      # Test a running container
      machine.succeeds("osctl ct start testct")

      _, output = machine.succeeds("osctl ct exec testct cat /proc/mounts")
      check_mounted.call(output)

      # Disable LXCFS
      machine.all_succeed(
        "osctl ct unset lxcfs testct",
        "osctl ct restart testct",
      )

      _, output = machine.succeeds("osctl ct exec testct cat /proc/mounts")

      if /lxcfs/ =~ output
        fail "found lxcfs mount when it should be disabled: #{output.inspect}"
      end
    '';
  };
})
