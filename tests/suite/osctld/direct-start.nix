import ../../make-test.nix (
  { pkgs }:
  {
    name = "osctld-direct-start";
    description = "Trusted legacy hooks support direct lxc-start without run identity environment";
    tags = [ "ci" ];
    machine = import ../../machines/vpsadminos/tank.nix pkgs;
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
      2.times do
        info = machine.osctl_json("ct show #{ct}")
        command = "exec lxc-start -P #{Shellwords.escape(info.fetch('lxc_path'))} -n #{ct} -d -l TRACE -o #{Shellwords.escape(info.fetch('log_file'))}"
        # Use the supported unprivileged host shell, not osctl ct start.
        machine.succeeds("printf '%s\\n' #{Shellwords.escape(command)} | osctl ct su #{ct} || { rc=$?; cat #{Shellwords.escape(info.fetch('log_file'))}; exit $rc; }")
        machine.wait_until_succeeds("osctl ct exec #{ct} true")
        init = machine.osctl_json("ct show #{ct}").fetch('init_pid').to_i
        expect(init).to be > 1
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
      machine.succeeds("osctl ct del --prune #{ct}")
    '';
  }
)
