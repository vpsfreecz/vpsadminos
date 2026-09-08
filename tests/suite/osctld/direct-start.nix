import ../../make-test.nix (
  { pkgs }:
  let
    netnsProbe = pkgs.writeText "ct-user-netns-probe.rb" ''
      require 'json'
      require 'socket'
      raise 'probe must run as an osctld user' if Process.uid == 0
      ARGV.drop(1).each do |target|
        UNIXSocket.open("/run/osctl/user-control/#{Process.uid}.sock") do |socket|
          socket.puts({cmd: 'ct_netns_setup', opts: {
            pool: 'tank', id: ARGV.fetch(0), init_pid: Integer(target),
            net_config: [{name: 'lo', ips: [{version: 4, address: '198.51.100.254', prefix: 32}], routes: []}]
          }}.to_json)
          response = JSON.parse(socket.readline)
          unless response.fetch('status') == false && response.fetch('message') == "Unsupported command 'ct_netns_setup'"
            raise "unsafe namespace request accepted: #{response.inspect}"
          end
        end
      end
    '';
  in
  {
    name = "osctld-direct-start";
    description = "Trusted legacy hooks support direct lxc-start without run identity environment";
    tags = [ "ci" ];
    machine = import ../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config.environment.etc."ct-user-netns-probe.rb".source = netnsProbe;
    };
    testScript = ''
      require 'shellwords'
      machine.start
      machine.wait_for_osctl_pool('tank')
      machine.wait_until_online
      ct = get_container_id
      machine.all_succeed(
        "osctl ct new --distribution alpine #{ct}",
        "osctl ct unset start-menu #{ct}",
        "osctl ct netif new routed #{ct} eth0",
        "osctl ct netif ip add #{ct} eth0 192.0.2.90/32",
      )
      victim = "#{ct}-victim"
      machine.all_succeed(
        "osctl ct new --distribution alpine #{victim}",
        "osctl ct unset start-menu #{victim}",
        "osctl ct start #{victim}",
        "osctl ct exec #{victim} sh -c 'echo retained > /root/netns-guard'",
      )
      victim_init = machine.osctl_json("ct show #{victim}").fetch('init_pid')
      host_loopback = machine.succeeds('ip -o address show dev lo')[1]
      victim_loopback = machine.succeeds("osctl ct exec #{victim} ip -o address show dev lo")[1]
      2.times do
        info = machine.osctl_json("ct show #{ct}")
        command = "exec lxc-start -P #{Shellwords.escape(info.fetch('lxc_path'))} -n #{ct} -d -l TRACE -o #{Shellwords.escape(info.fetch('log_file'))}"
        # Use the supported unprivileged host shell, not osctl ct start.
        machine.succeeds("printf '%s\\n' #{Shellwords.escape(command)} | osctl ct su #{ct} || { rc=$?; cat #{Shellwords.escape(info.fetch('log_file'))}; exit $rc; }")
        machine.wait_until_succeeds("osctl ct exec #{ct} true")
        init = machine.osctl_json("ct show #{ct}").fetch('init_pid').to_i
        expect(init).to be > 1
        # Exercise the real writable per-user socket with both host and
        # foreign container namespace PIDs, not a root-only mock dispatch.
        probe = "ruby /etc/ct-user-netns-probe.rb #{ct} 1 #{victim_init} #{init}"
        machine.succeeds("printf '%s\\n' #{Shellwords.escape(probe)} | osctl ct su #{ct}")
        expect(machine.succeeds('ip -o address show dev lo')[1]).to eq(host_loopback)
        expect(machine.succeeds("osctl ct exec #{victim} ip -o address show dev lo")[1]).to eq(victim_loopback)
        %w[syslog tracing].each do |namespace|
          expected = machine.succeeds("readlink /proc/#{init}/ns/#{namespace}")[1]
          expect(machine.succeeds("osctl ct exec #{ct} readlink /proc/self/ns/#{namespace}")[1]).to eq(expected)
        end
        cgroup = '/' + info.fetch('group_path')
        payload = "#{cgroup}/lxc.payload.#{ct}"
        actual_cgroup = machine.succeeds("cat /proc/#{init}/cgroup")[1].strip
        # The Alpine image's cgroups-mount service moves init into this leaf.
        expect(actual_cgroup).to eq("0::#{payload}/init.scope")
        ownership = machine.succeeds("stat -c %u:%g /run/osctl/cgroup#{cgroup}")[1]
        machine.succeeds("printf '%s\\n' true | osctl ct su #{ct}")
        expect(machine.succeeds("stat -c %u:%g /run/osctl/cgroup#{cgroup}")[1]).to eq(ownership)
        expect(machine.osctl_json("ct show #{ct}").fetch('init_pid').to_i).to eq(init)
        machine.all_succeed(
          "! tr '\\0' '\\n' < /proc/#{init}/environ | grep -q '^OSCTL_RUN_ID='",
          "osctl ct exec #{ct} grep -w memory /sys/fs/cgroup/cgroup.controllers",
          'ping -c 1 192.0.2.90',
          "osctl ct stop #{ct}",
        )
        info = machine.osctl_json("ct show #{ct}")
        expect(info.fetch('state')).to eq('stopped')
        expect(info.fetch('recovery_tainted')).to be(false)
      end
      machine.all_succeed(
        "osctl ct exec #{victim} grep -Fx retained /root/netns-guard",
        "osctl ct stop #{victim}",
        "osctl ct del --prune #{victim}",
        "osctl ct del --prune #{ct}",
      )
    '';
  }
)
