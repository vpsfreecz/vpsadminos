import ../../make-test.nix (
  { pkgs }:
  {
    name = "cgroups-devices-v2";

    description = ''
      Test device access on cgroupv2
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/with-tank.nix {
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

        if prog['attach_type'] != 'cgroup_device'
          fail "expected attach_type cgroup_device on cgroup #{cgroup.inspect}, got #{prog['attach_type'].inspect}"
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
        "osctl ct unset start-menu testct",
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

      default_cgroup = "/sys/fs/cgroup/osctl/pool.tank/group.default"
      shared_cgroup = "#{default_cgroup}/user.testct"
      testct_cgroup = "#{shared_cgroup}/ct.testct"
      testct2_cgroup = "#{shared_cgroup}/ct.testct2"
      promoted_default_prog_name = check_prog_list!(default_cgroup)

      check_tun_access = lambda do |ct, read:, write:|
        { '<' => read, '>' => write }.each do |redirection, allowed|
          command = "osctl ct exec #{ct} sh -c 'exec 3#{redirection}/root/test-tun'"

          if allowed
            machine.succeeds(command)
          else
            _, output = machine.fails(command)
            expect(output).to include('Operation not permitted')
          end
        end
      end

      describe 'container devices under a shared user cgroup', order: :defined do
        before(:context) do
          machine.all_succeed(
            "osctl ct new --distribution alpine --user testct testct2",
            "osctl ct unset start-menu testct2",
            "osctl ct start testct2",
            "osctl ct devices add -p testct2 char 10 200 rwm /dev/net/tun",
            "osctl ct exec testct mknod /root/test-tun c 10 200",
            "osctl ct exec testct2 mknod /root/test-tun c 10 200"
          )

          # Keep nodes independent of device configuration and only open them:
          # reading or writing an unattached TUN device has unrelated errors.
          check_tun_access.call('testct', read: true, write: true)
          check_tun_access.call('testct2', read: true, write: true)
          expect(check_prog_list!(testct_cgroup)).to eq(new_ct_prog_name)
          expect(check_prog_list!(testct2_cgroup)).to eq(new_ct_prog_name)
          expect(machine.succeeds("osctl healthcheck -a")[1]).to eq("No errors detected.\n")
        end

        it 'keeps a sibling device allowed when removed from one container' do
          machine.succeeds("osctl ct devices del testct char 10 200")

          check_tun_access.call('testct', read: false, write: false)
          check_tun_access.call('testct2', read: true, write: true)
          expect(check_prog_list!(testct_cgroup)).to eq(ct_prog_name)
          expect(check_prog_list!(testct2_cgroup)).to eq(new_ct_prog_name)
          expect(check_prog_list!(default_cgroup)).to eq(promoted_default_prog_name)
          expect(machine.succeeds("osctl healthcheck -a")[1]).to eq("No errors detected.\n")
        end

        it 'keeps a sibling mode unchanged when restricting one container' do
          machine.succeeds("osctl ct devices add -p testct char 10 200 rwm /dev/net/tun")
          check_tun_access.call('testct', read: true, write: true)
          expect(check_prog_list!(testct_cgroup)).to eq(new_ct_prog_name)
          expect(machine.succeeds("osctl healthcheck -a")[1]).to eq("No errors detected.\n")

          machine.succeeds("osctl ct devices chmod testct char 10 200 r")

          check_tun_access.call('testct', read: true, write: false)
          check_tun_access.call('testct2', read: true, write: true)
          restricted_prog_name = check_prog_list!(testct_cgroup)
          expect(restricted_prog_name).not_to eq(ct_prog_name)
          expect(restricted_prog_name).not_to eq(new_ct_prog_name)
          expect(check_prog_list!(testct2_cgroup)).to eq(new_ct_prog_name)
          expect(check_prog_list!(default_cgroup)).to eq(promoted_default_prog_name)
          expect(machine.succeeds("osctl healthcheck -a")[1]).to eq("No errors detected.\n")
        end

        it 'still removes device access recursively from the parent group' do
          machine.succeeds("osctl group devices del --recursive /default char 10 200")

          check_tun_access.call('testct', read: false, write: false)
          check_tun_access.call('testct2', read: false, write: false)

          # On v2, the parent program restricts effective access without
          # requiring the containers' own programs to be replaced.
          check_prog_list!(testct_cgroup)
          check_prog_list!(testct2_cgroup)
          expect(check_prog_list!(default_cgroup)).to eq(default_prog_name)
          expect(machine.succeeds("osctl healthcheck -a")[1]).to eq("No errors detected.\n")
        end
      end
    '';
  }
)
