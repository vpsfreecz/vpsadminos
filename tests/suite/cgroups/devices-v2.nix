import ../../make-test.nix (pkgs: {
  name = "cgroups-devices-v2";

  description = ''
    Test device access on cgroupv2
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
    def check_prog_list!(cgroup)
      _, output = machine.succeeds("bpftool -j cgroup list #{cgroup}")
      prog_list = JSON.parse(output.strip)

      if prog_list.length != 1
        fail "expected one bpf program on #{cgroup.inspect}, got #{prog_list.length}"
      end

      prog = prog_list[0]

      if prog['attach_type'] != 'device'
        fail "expected attach_type device on cgroup #{cgroup.inspect}, got #{prog['attach_type'].inspect}"
      end

      if prog['attach_flags'] != 'multi'
        fail "expected attach_flags multi on cgroup #{cgroup.inspect}, got #{prog['attach_flags'].inspect}"
      end

      prog['name']
    end

    machine.wait_for_osctl_pool("tank")
    machine.wait_until_online
    machine.all_succeed(
      "osctl ct new --distribution alpine testct",
      "osctl ct start testct",
    )

    # Check BPF program on container cgroup
    ct_prog_name = check_prog_list!("/sys/fs/cgroup/osctl/pool.tank/group.default/user.testct/ct.testct")

    # Check group /default
    default_prog_name = check_prog_list!("/sys/fs/cgroup/osctl/pool.tank/group.default")

    if ct_prog_name != default_prog_name
      fail "expected container (#{ct_prog_name}) and /default (#{default_prog_name}) programs to have the same name"
    end

    # Check group /
    root_prog_name = check_prog_list!("/sys/fs/cgroup/osctl/pool.tank")

    if default_prog_name != root_prog_name
      fail "expected /default (#{default_prog_name}) and / (#{root_prog_name}) programs to have the same name"
    end

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

    new_ct_prog_name = check_prog_list!("/sys/fs/cgroup/osctl/pool.tank/group.default/user.testct/ct.testct")

    if new_ct_prog_name == ct_prog_name
      fail "expected different container program than #{ct_prog_name}"
    end

    # Check that the container's root cgroup is the same
    new_root_prog_name = check_prog_list!("/sys/fs/cgroup/osctl/pool.tank")

    if new_root_prog_name == root_prog_name
      fail "expected different root program than #{root_prog_name}"
    end
  '';
})
