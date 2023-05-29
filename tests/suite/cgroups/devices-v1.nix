import ../../make-test.nix (pkgs: {
  name = "cgroups-devices-v1";

  description = ''
    Test device access on cgroupv1
  '';

  machine = import ../../machines/with-tank.nix {
    inherit pkgs;
    config =
      { config, ... }:
      {
        boot.enableUnifiedCgroupHierarchy = false;
      };
  };

  testScript = ''
    allowed_devices = [
      %w(c 1:3   rwm /dev/null    ),
      %w(c 1:5   rwm /dev/zero    ),
      %w(c 1:7   rwm /dev/full    ),
      %w(c 1:8   rwm /dev/random  ),
      %w(c 1:9   rwm /dev/urandom ),
      %w(c 1:11  rwm /dev/kmsg    ),
      %w(c 5:0   rwm /dev/tty     ),
      %w(c 5:1   rwm /dev/console ),
      %w(c 5:2   rwm /dev/ptmx    ),
      %w(c 136:* rwm /dev/tty*    ),
      %w(b *:*   m   block        ),
      %w(c *:*   m   char         ),
    ]

    def check_allowlist(allowed_devices, device_list)
      allowed_devices.each do |allowed|
        found = device_list.detect do |dev|
          dev[0..2] == allowed[0..2]
        end

        if found.nil?
          fail "device '#{allowed.join}' not allowed"
        end

        device_list.delete(found)
      end

      if device_list.any?
        fail "devices allowed, but shouldn't be: #{device_list.map(&:join).join('; ')}"
      end
    end

    machine.wait_for_osctl_pool("tank")
    machine.wait_until_online
    machine.all_succeed(
      "osctl ct new --distribution alpine testct",
      "osctl ct unset start-menu testct",
      "osctl ct start testct",
    )

    # Verify cgroup configuration of the default list of allowed devices
    _, output = machine.succeeds("cat /sys/fs/cgroup/devices/osctl/pool.tank/group.default/user.testct/ct.testct/devices.list")
    device_list = output.strip.split("\n").map { |line| line.strip.split(" ") }
    check_allowlist(allowed_devices, device_list)

    # Check that the container's root cgroup is the same
    _, output = machine.succeeds("osctl ct exec testct cat /sys/fs/cgroup/devices/devices.list")
    device_list = output.strip.split("\n").map { |line| line.strip.split(" ") }
    check_allowlist(allowed_devices, device_list)

    # Check read/write access
    machine.all_succeed(
      "osctl ct exec testct dd if=/dev/zero of=/dev/null bs=1M count=1",
      "osctl ct exec testct dd if=/dev/random of=/dev/null bs=1M count=1",
    )

    # Check mknod of inaccessible devices
    _, vda = machine.succeeds("stat -c '%Hr %Lr' /dev/vda")

    machine.all_succeed(
      "osctl ct exec testct mknod /dev/test1 b 88 99",
      "osctl ct exec testct mknod /dev/test2 c 99 88",
      "osctl ct exec testct mknod /dev/vda b #{vda.strip}",
    )

    # Accessing mknod-ed devices returns error
    %w(/dev/test1 /dev/test2 /dev/vda).each do |dev|
      _, output = machine.fails("osctl ct exec testct head #{dev}")
      unless output.include?("Operation not permitted")
        fail "expected read from #{dev} to fail: #{output.inspect}"
      end

    _, output = machine.fails("osctl ct exec testct dd if=/dev/zero of=#{dev} bs=1M count=1")
      unless output.include?("Operation not permitted")
        fail "expected write to #{dev} to fail: #{output.inspect}"
      end
    end

    # Check mknod of accessible devices
    machine.all_succeed(
      "osctl ct exec testct mknod /root/mynull c 1 3",
      "osctl ct exec testct dd if=/dev/zero of=/root/mynull bs=1M count=1",
    )

    # Add custom device and verify cgroup configuration
    machine.succeeds("osctl ct devices add -p testct char 10 200 rwm /dev/net/tun")
    _, output = machine.succeeds("cat /sys/fs/cgroup/devices/osctl/pool.tank/group.default/user.testct/ct.testct/devices.list")
    device_list = output.strip.split("\n").map { |line| line.strip.split(" ") }
    check_allowlist(allowed_devices + [%w(c 10:200 rwm /dev/net/tun)], device_list)

    # Check that the container's root cgroup is the same
    _, output = machine.succeeds("osctl ct exec testct cat /sys/fs/cgroup/devices/devices.list")
    device_list = output.strip.split("\n").map { |line| line.strip.split(" ") }
    check_allowlist(allowed_devices + [%w(c 10:200 rwm /dev/net/tun)], device_list)
  '';
})
