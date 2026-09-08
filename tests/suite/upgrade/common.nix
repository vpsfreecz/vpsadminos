# Shared native test; each named case pins only its predecessor revision.
{
  name,
  revision,
  kernelPrefix,
  configuration ? null,
}:
args:
let
  previous = builtins.getFlake "github:vpsfreecz/vpsadminos/${revision}";
  current = builtins.getFlake (toString ../../..);
  system = args.system or builtins.currentSystem;
  cgroupVersion = args.cgroupVersion or 2;
  cgroupConfig.boot.enableUnifiedCgroupHierarchy = cgroupVersion == 2;
  nextSystem =
    (current.lib.vpsadminosSystem {
      inherit system;
      configuration = args.configuration or null;
      modules = [
        ../../configs/vpsadminos/base.nix
        ../../configs/vpsadminos/pool-tank.nix
        { osctl.test-shell.shells = 1; }
        cgroupConfig
      ];
    }).config.system.build.toplevel;
in
import (previous.outPath + "/tests/make-test.nix")
  (
    { pkgs }:
    let
      resourceProbe = pkgs.pkgsStatic.stdenv.mkDerivation {
        name = "upgrade-resource-probe";
        dontUnpack = true;
        buildPhase = ''
          $CC -O2 -Wall -Wextra -Werror ${./resource-probe.c} -o resource-probe
        '';
        installPhase = ''
          install -Dm755 resource-probe $out/bin/resource-probe
        '';
      };

      workload = pkgs.writeScript "upgrade-workload" ''
        #!/bin/sh
        set -e
        trap 'exit 0' TERM INT HUP PWR
        # This fixture replaces Alpine init, so invoke the guest's generated
        # network configuration just as its normal boot would do.
        /sbin/ifup -a
        mkdir -p /upgrade
        echo retained-data > /upgrade/data
        (exec sleep 86400) &
        echo $! > /upgrade/worker.pid
        (exec /sbin/upgrade-busybox httpd -f -p 8080 -h /upgrade > /upgrade/http.log 2>&1) &
        echo $! > /upgrade/http.pid
        echo UPGRADE_READY
        while IFS= read -r line; do
          printf 'UPGRADE_ECHO:%s\n' "$line"
        done
      '';

      stoppedNetwork = pkgs.writeScript "upgrade-stopped-network" ''
        #!/bin/sh
        set -eu
        ping -c 1 255.255.255.254
        grep -Fx predecessor-data /root/retained
        echo stopped-runscript-data > /root/stopped-runscript
      '';

      consoleClient = pkgs.writeText "upgrade-console.rb" ''
        require 'pty'
        require 'timeout'
        output = String.new
        PTY.spawn('osctl', 'ct', 'console', ARGV.fetch(0)) do |reader, writer, pid|
          begin
            Timeout.timeout(30) do
              output << reader.readpartial(4096) until output.include?('Press Ctrl+a q')
              writer.write("#{ARGV.fetch(1)}\n")
              output << reader.readpartial(4096) until output.include?("UPGRADE_ECHO:#{ARGV.fetch(1)}")
            end
            writer.write("\x01q")
            _, status = Timeout.timeout(10) { Process.wait2(pid) }
            raise "console failed: #{output}" unless status.success?
            puts output
          ensure
            unless status
              Process.kill('TERM', pid) rescue nil
              Process.wait(pid) rescue nil
            end
          end
        end
      '';
    in
    {
      name = "upgrade-${name}" + (if cgroupVersion == 1 then "-v1" else "");
      description = "Switch from ${revision} to the current checkout on ${kernelPrefix}";
      tags = [
        "upgrade"
        "ci"
      ];

      machine = import (previous.outPath + "/tests/machines/vpsadminos/with-tank.nix") {
        inherit pkgs;
        config = {
          # Only the test transport follows the current runner. Boot the pinned
          # predecessor's real daemon, LXC, kernel, ZFS and system policy.
          disabledModules = [ (previous.outPath + "/os/modules/osctl/test-shell.nix") ];
          imports = [
            ../../../os/modules/osctl/test-shell.nix
            cgroupConfig
          ];
          system.extraDependencies = [ nextSystem ];
        };
      };

      testScript = ''
        require 'json'
        require 'shellwords'

        machine.start
        machine.wait_for_osctl_pool('tank')
        machine.wait_until_online
        expect(machine.succeeds("stat -f -c %T /sys/fs/cgroup")[1].strip).to eq('${
          if cgroupVersion == 2 then "cgroup2fs" else "tmpfs"
        }')
        before_kernel = machine.succeeds('uname -r')[1].strip
        expect(before_kernel).to start_with('${kernelPrefix}')
        expect(machine.succeeds('readlink -f /run/current-system')[1].strip).not_to eq('${nextSystem}')
        before_boot = machine.succeeds('cat /proc/sys/kernel/random/boot_id')[1].strip
        before_bpffs = machine.succeeds('stat -c %d:%i /sys/fs/bpf')[1].strip
        daemon_identity = lambda do
          status = machine.succeeds('sv status osctld')[1]
          supervisor = status.match(/\(pid (\d+)\)/).captures.first
          # sv tracks the logging supervisor, not the daemon. Killing that
          # supervisor leaves its child alive and creates a second daemon.
          pids = machine.succeeds("pgrep -P #{supervisor} -f '^osctld: main$'")[1].split
          expect(pids.length).to eq(1)
          pid = pids.first
          [pid, machine.succeeds("awk '{print $22}' /proc/#{pid}/stat")[1].strip]
        end
        before_daemon = daemon_identity.call
        machine.push_file('${consoleClient}', '/root/upgrade-console.rb')
        machine.push_file('${stoppedNetwork}', '/root/upgrade-stopped-network')
        machine.succeeds('chmod 500 /root/upgrade-stopped-network')

        # A separate ordinary-init CT contains bounded OOM/fork workloads so
        # they cannot invalidate the two long-lived continuity workloads.
        cgroup_version = ${toString cgroupVersion}
        machine.all_succeed(
          'osctl ct new --distribution alpine limited',
          'osctl ct unset start-menu limited',
          'osctl ct set cpu-limit limited 25',
          'osctl ct set memory-limit limited 134217728 0',
          "osctl ct cgparams set -v #{cgroup_version} limited pids.max 64",
          "osctl ct cgparams set -v #{cgroup_version} limited cpuset.cpus 0",
          'osctl ct devices chmod limited char 1 5 r',
          'osctl ct mount limited',
          'zfs create tank/upgrade-bind',
          'echo inherited-bind > /tank/upgrade-bind/marker',
          'osctl ct mounts new --fs /tank/upgrade-bind --type bind --opts bind,create=dir --mountpoint /mnt/inherited limited',
        )
        limited_root = machine.osctl_json('ct show limited').fetch('rootfs')
        machine.push_file('${resourceProbe}/bin/resource-probe', "#{limited_root}/bin/upgrade-resource-probe", preserve: true)
        machine.succeeds('osctl ct start limited')
        machine.wait_until_succeeds('osctl ct exec limited rc-service syslog status')
        limited_init = machine.osctl_json('ct show limited').fetch('init_pid')
        limited_identity = machine.succeeds("awk '{print $22}' /proc/#{limited_init}/stat")[1]

        # Resolve the actual controller mount, including combined v1 mounts.
        # Limits belong to the CT's base parent, not its payload leaf.
        cgroup_base = 'osctl/pool.tank/group.default/user.limited/ct.limited'
        cgroup_file = lambda do |parameter|
          candidates = if cgroup_version == 2
                         '/run/osctl/cgroup /sys/fs/cgroup'
                       else
                         '/run/osctl/cgroup/* /sys/fs/cgroup/*'
                       end
          machine.succeeds("for root in #{candidates}; do file=\"$root/#{cgroup_base}/#{parameter}\"; if test -f \"$file\"; then echo \"$file\"; exit 0; fi; done; exit 1")[1].strip
        end
        read_parameter = lambda do |parameter|
          machine.succeeds("cat #{Shellwords.escape(cgroup_file.call(parameter))}")[1].strip
        end
        counter = lambda do |parameter, key|
          output = read_parameter.call(parameter)
          key ? Integer(output.lines.find { |line| line.split.first == key }.split.last) : Integer(output)
        end
        assert_limits = lambda do |cpu, pids, memory = 134217728, cpuset = '0'|
          expect(read_parameter.call(cgroup_version == 2 ? 'cpu.max' : 'cpu.cfs_quota_us')).to eq(
            cgroup_version == 2 ? "#{cpu * 1000} 100000" : (cpu * 1000).to_s,
          )
          expect(read_parameter.call(cgroup_version == 2 ? 'memory.max' : 'memory.limit_in_bytes')).to eq(memory.to_s)
          expect(read_parameter.call(cgroup_version == 2 ? 'memory.swap.max' : 'memory.memsw.limit_in_bytes')).to eq(
            cgroup_version == 2 ? '0' : memory.to_s,
          )
          expect(read_parameter.call('pids.max')).to eq(pids.to_s)
          expect(machine.succeeds("awk '/^Cpus_allowed_list:/ {print $2}' /proc/#{limited_init}/status")[1].strip).to eq(cpuset)
          throttled = counter.call('cpu.stat', 'nr_throttled')
          machine.succeeds('timeout 40 osctl ct exec limited /bin/upgrade-resource-probe cpu', timeout: 60)
          expect(counter.call('cpu.stat', 'nr_throttled')).to be > throttled
          pids_denied = counter.call('pids.events', 'max')
          machine.succeeds('timeout 40 osctl ct exec limited /bin/upgrade-resource-probe pids', timeout: 60)
          expect(counter.call('pids.events', 'max')).to be > pids_denied
          memory_file, memory_key = cgroup_version == 2 ? ['memory.events', 'oom_kill'] : ['memory.failcnt', nil]
          memory_denied = counter.call(memory_file, memory_key)
          machine.succeeds('timeout 40 osctl ct exec limited /bin/upgrade-resource-probe memory', timeout: 60)
          expect(counter.call(memory_file, memory_key)).to be > memory_denied
          machine.succeeds('osctl ct exec limited dd if=/dev/zero of=/dev/null bs=1 count=1')
          denied = machine.fails('osctl ct exec limited dd if=/dev/null of=/dev/zero bs=1 count=0')[1]
          expect(denied).to include('Operation not permitted')
          expect(machine.osctl_json('ct show limited').fetch('init_pid')).to eq(limited_init)
          expect(machine.succeeds("awk '{print $22}' /proc/#{limited_init}/stat")[1]).to eq(limited_identity)
        end
        assert_limits.call(25, 64)

        # Real IDs and pins detect accidental replacement, not just reuse of
        # a path name. This device policy has no maps: compare that explicitly.
        bpf_identity = lambda do |ctid = 'limited'|
          next nil if cgroup_version == 1
          cgroup = File.dirname(cgroup_file.call('cgroup.procs')).sub('user.limited/ct.limited', "user.#{ctid}/ct.#{ctid}")
          programs = JSON.parse(machine.succeeds("bpftool -j cgroup list #{cgroup}")[1])
          device = programs.select { |program| program.fetch('attach_type') == 'cgroup_device' }
          expect(device.length).to eq(1)
          id = device.first.fetch('id')
          program = JSON.parse(machine.succeeds("bpftool -j prog show id #{id}")[1])
          expect(program.fetch('map_ids', [])).to eq([])
          pins = machine.succeeds("for root in /run/osctl/bpf /sys/fs/bpf; do if test -d \"$root/osctl/pools/tank/links\"; then find \"$root/osctl/pools/tank/links\" -maxdepth 1 -name '*#{ctid}*'; fi; done")[1].lines.map(&:strip).uniq
          expect(pins).not_to be_empty
          links = pins.map do |pin|
            link = JSON.parse(machine.succeeds("bpftool -j link show pinned #{Shellwords.escape(pin)}")[1])
            [File.basename(pin), link.fetch('id'), link.fetch('prog_id')]
          end.uniq.sort
          expect(links.map(&:last).uniq).to eq([id])
          [id, program.fetch('tag'), program.fetch('map_ids', []), links]
        end
        inherited_bpf = bpf_identity.call

        # Include all three inherited stopped states, not only fresh objects
        # created by the new daemon. Do not start or mount neverstarted here.
        %w[neverstarted mountedstopped previouslyrun].each_with_index do |ctid, index|
          machine.all_succeed(
            "osctl ct new --distribution alpine #{ctid}",
            "osctl ct unset start-menu #{ctid}",
            "osctl ct netif new routed #{ctid} eth0",
            "osctl ct netif ip add #{ctid} eth0 192.0.2.#{20 + index}/32",
          )
        end
        machine.succeeds('osctl ct mount mountedstopped')
        mounted_root = machine.osctl_json('ct show mountedstopped').fetch('rootfs')
        machine.succeeds("echo mounted-data > #{Shellwords.escape(mounted_root)}/mounted-data")
        machine.succeeds('osctl ct start previouslyrun')
        machine.wait_until_succeeds('osctl ct exec previouslyrun rc-service networking status')
        machine.all_succeed(
          "osctl ct exec previouslyrun sh -c 'echo predecessor-data > /root/retained'",
          'osctl ct stop previouslyrun',
        )

        snapshots = {}
        %w[upgrade1 upgrade2].each_with_index do |ctid, index|
          address = "192.0.2.#{10 + index}"
          machine.all_succeed(
            "osctl ct new --distribution alpine #{ctid}",
            "osctl ct unset start-menu #{ctid}",
            "osctl ct netif new routed #{ctid} eth0",
            "osctl ct netif ip add #{ctid} eth0 #{address}/32",
            "osctl ct mount #{ctid}",
          )
          info = machine.osctl_json("ct show #{ctid}")
          # The minimal image does not install an HTTP server. Supply the
          # workload explicitly, not as an assumed guest package or policy.
          machine.push_file('${pkgs.pkgsStatic.busybox}/bin/busybox', "#{info.fetch('rootfs')}/sbin/upgrade-busybox", preserve: true)
          machine.push_file('${workload}', "#{info.fetch('rootfs')}/sbin/upgrade-workload", preserve: true)
          machine.all_succeed(
            "osctl ct set init-cmd #{ctid} /sbin/upgrade-workload",
            "osctl ct start #{ctid}",
          )
          machine.wait_until_succeeds("osctl ct exec #{ctid} test -s /upgrade/worker.pid")
          info = machine.osctl_json("ct show #{ctid}")
          init = info.fetch('init_pid').to_i
          expect(init).to be > 1
          netif = machine.osctl_json("ct netif ls #{ctid}").find { |v| v.fetch('name') == 'eth0' }
          veth = netif.fetch('veth')
          machine.all_succeed(
            "ping -c 1 #{address}",
            "curl --fail --max-time 10 http://#{address}:8080/data | grep -Fx retained-data || { osctl ct exec #{ctid} cat /upgrade/http.log; exit 1; }",
            "ruby /root/upgrade-console.rb #{ctid} before-upgrade",
            "! tr '\\0' '\\n' < /proc/#{init}/environ | grep -q '^OSCTL_RUN_ID='",
          )
          snapshots[ctid] = {
            address:,
            init:,
            init_start: machine.succeeds("awk '{print $22}' /proc/#{init}/stat")[1],
            cgroup: machine.succeeds("cat /proc/#{init}/cgroup")[1],
            mounts: machine.succeeds("cat /proc/#{init}/mountinfo")[1],
            bpf: bpf_identity.call(ctid),
            veth:,
            ifindex: machine.succeeds("cat /sys/class/net/#{veth}/ifindex")[1],
            console: machine.succeeds("stat -c %i /run/osctl/pools/tank/console/#{ctid}/tty0.sock")[1],
            worker: machine.succeeds("osctl ct exec #{ctid} sh -c 'cat /proc/$(cat /upgrade/worker.pid)/stat'")[1].split.values_at(0, 21),
            http: machine.succeeds("osctl ct exec #{ctid} sh -c 'cat /proc/$(cat /upgrade/http.pid)/stat'")[1].split.values_at(0, 21),
          }
        end

        # 'test' is normal live generation activation without bootloader changes.
        machine.succeeds('${nextSystem}/bin/switch-to-configuration test', timeout: 300)
        machine.wait_for_osctl_pool('tank')
        expect(machine.succeeds('uname -r')[1].strip).to eq(before_kernel)
        expect(machine.succeeds('cat /proc/sys/kernel/random/boot_id')[1].strip).to eq(before_boot)
        expect(machine.succeeds('readlink -f /run/current-system')[1].strip).to eq('${nextSystem}')
        expect(daemon_identity.call).not_to eq(before_daemon)
        expect(machine.succeeds('stat -c %d:%i /run/osctl/bpf')[1].strip).to eq(before_bpffs)
        expect(machine.succeeds('stat -f -c %T /run/osctl/bpf')[1].strip).to eq('bpf_fs')

        assert_retained = lambda do
          expect(machine.osctl_json('ct show limited').fetch('init_pid')).to eq(limited_init)
          machine.succeeds('osctl ct exec limited grep -Fx inherited-bind /mnt/inherited/marker')
          expect(bpf_identity.call).to eq(inherited_bpf)
          snapshots.each do |ctid, saved|
            info = machine.osctl_json("ct show #{ctid}")
            expect(info.fetch('state')).to eq('running')
            expect(info.fetch('init_pid').to_i).to eq(saved.fetch(:init))
            init = saved.fetch(:init)
            expect(machine.succeeds("awk '{print $22}' /proc/#{init}/stat")[1]).to eq(saved.fetch(:init_start))
            expect(machine.succeeds("cat /proc/#{init}/cgroup")[1]).to eq(saved.fetch(:cgroup))
            expect(machine.succeeds("cat /proc/#{init}/mountinfo")[1]).to eq(saved.fetch(:mounts))
            expect(bpf_identity.call(ctid)).to eq(saved.fetch(:bpf))
            netif = machine.osctl_json("ct netif ls #{ctid}").find { |v| v.fetch('name') == 'eth0' }
            expect(netif.fetch('veth')).to eq(saved.fetch(:veth))
            expect(machine.succeeds("cat /sys/class/net/#{saved.fetch(:veth)}/ifindex")[1]).to eq(saved.fetch(:ifindex))
            expect(machine.succeeds("stat -c %i /run/osctl/pools/tank/console/#{ctid}/tty0.sock")[1]).to eq(saved.fetch(:console))
            worker = machine.succeeds("osctl ct exec #{ctid} sh -c 'cat /proc/$(cat /upgrade/worker.pid)/stat'")[1].split.values_at(0, 21)
            expect(worker).to eq(saved.fetch(:worker))
            http = machine.succeeds("osctl ct exec #{ctid} sh -c 'cat /proc/$(cat /upgrade/http.pid)/stat'")[1].split.values_at(0, 21)
            expect(http).to eq(saved.fetch(:http))
            machine.all_succeed(
              "osctl ct exec #{ctid} grep -Fx retained-data /upgrade/data",
              "ruby /root/upgrade-console.rb #{ctid} after-upgrade",
              "ping -c 1 #{saved.fetch(:address)}",
              "curl --fail --max-time 10 http://#{saved.fetch(:address)}:8080/data | grep -Fx retained-data",
            )
          end
        end
        assert_retained.call

        # Reusing a private hierarchy must be idempotent after restrictions
        # have settled, not just during the first daemon startup.
        private_mounts = lambda do
          pid = daemon_identity.call.first
          machine.succeeds("awk 'index($5, \"/run/osctl/cgroup\") == 1 || index($5, \"/run/osctl/bpf\") == 1 {print}' /proc/#{pid}/mountinfo")[1]
        end
        adopted_mounts = private_mounts.call
        expect(adopted_mounts).not_to be_empty
        2.times do
          machine.succeeds('${nextSystem}/bin/switch-to-configuration test', timeout: 300)
          machine.wait_for_osctl_pool('tank')
          expect(private_mounts.call).to eq(adopted_mounts)
          assert_retained.call
        end

        %w[graceful abrupt].each do |mode|
          prior_daemon = daemon_identity.call
          if mode == 'graceful'
            machine.succeeds('sv -w 90 restart osctld', timeout: 120)
          else
            machine.succeeds("kill -KILL #{prior_daemon.first}")
            machine.wait_until_succeeds("! kill -0 #{prior_daemon.first}")
          end
          machine.wait_for_service('osctld')
          machine.wait_until_succeeds("pgrep -f '^osctld: main$'")
          machine.wait_for_osctl_pool('tank')
          expect(daemon_identity.call).not_to eq(prior_daemon)
          expect(private_mounts.call).to eq(adopted_mounts)
          assert_retained.call
        end

        assert_limits.call(25, 64)
        machine.all_succeed(
          'osctl ct set cpu-limit limited 50',
          "osctl ct cgparams set -v #{cgroup_version} limited pids.max 48",
          "osctl ct cgparams set -v #{cgroup_version} limited cpuset.cpus 1",
          'osctl ct set memory-limit limited 167772160 0',
          'osctl ct devices chmod limited char 1 5 rwm',
          'osctl ct exec limited dd if=/dev/null of=/dev/zero bs=1 count=0',
          'osctl ct devices chmod limited char 1 5 r',
        )
        assert_limits.call(50, 48, 167772160, '1')
        inherited_bpf = bpf_identity.call

        # Mutating this inherited bind must not propagate into either sibling
        # or alter the host source mount. Re-adding it also tests live mapping.
        source_mount = machine.succeeds('findmnt -n -o ID,TARGET,SOURCE -T /tank/upgrade-bind')[1]
        2.times do
          machine.succeeds('osctl ct mounts deactivate limited /mnt/inherited')
          machine.fails('osctl ct exec limited test -e /mnt/inherited/marker')
          machine.succeeds('osctl ct mounts activate limited /mnt/inherited')
          machine.succeeds('osctl ct exec limited grep -Fx inherited-bind /mnt/inherited/marker')
          machine.succeeds('osctl ct mounts del limited /mnt/inherited')
          machine.fails('osctl ct exec limited test -e /mnt/inherited/marker')
          machine.succeeds('osctl ct mounts new --fs /tank/upgrade-bind --type bind --opts bind,create=dir --mountpoint /mnt/inherited limited')
          machine.succeeds("osctl ct exec limited sh -c 'echo guest-owned > /mnt/inherited/guest-marker; test \"$(stat -c %u:%g /mnt/inherited/guest-marker)\" = 0:0'")
          %w[upgrade1 upgrade2].each do |ctid|
            machine.fails("osctl ct exec #{ctid} test -e /mnt/inherited/marker")
          end
          expect(machine.succeeds('findmnt -n -o ID,TARGET,SOURCE -T /tank/upgrade-bind')[1]).to eq(source_mount)
          assert_retained.call
        end
        machine.succeeds('osctl ct restart limited')
        machine.wait_until_succeeds('osctl ct exec limited rc-service syslog status')
        limited_init = machine.osctl_json('ct show limited').fetch('init_pid')
        limited_identity = machine.succeeds("awk '{print $22}' /proc/#{limited_init}/stat")[1]
        machine.succeeds('osctl ct exec limited grep -Fx guest-owned /mnt/inherited/guest-marker')
        assert_limits.call(50, 48, 167772160, '1')
        machine.all_succeed('osctl ct stop limited', 'osctl ct del --prune limited')
        machine.succeeds("test ! -e /run/osctl/cgroup/#{cgroup_base}") if cgroup_version == 2
        machine.succeeds("test -z \"$(find /run/osctl/bpf/osctl/pools/tank/links -name '*limited*')\"") if cgroup_version == 2

        # The transient attach path must work on an inherited stopped CT,
        # without starting it or losing its persistent root filesystem.
        machine.all_succeed(
          'osctl ct exec -rn previouslyrun ping -c 1 255.255.255.254',
          'osctl ct runscript -rn previouslyrun /root/upgrade-stopped-network',
          'osctl ct exec -r previouslyrun grep -Fx stopped-runscript-data /root/stopped-runscript',
        )
        expect(machine.osctl_json('ct show previouslyrun').fetch('state')).to eq('stopped')
        %w[neverstarted mountedstopped previouslyrun].each_with_index do |ctid, index|
          expect(machine.osctl_json("ct show #{ctid}").fetch('state')).to eq('stopped')
          machine.succeeds("osctl ct start #{ctid}")
          machine.wait_until_succeeds("osctl ct exec #{ctid} rc-service networking status")
          machine.wait_until_succeeds("ping -c 1 192.0.2.#{20 + index}")
          if ctid == 'mountedstopped'
            machine.succeeds('osctl ct exec mountedstopped grep -Fx mounted-data /mounted-data')
          elsif ctid == 'previouslyrun'
            machine.succeeds('osctl ct exec previouslyrun grep -Fx predecessor-data /root/retained')
          end
          machine.succeeds("osctl ct restart #{ctid}")
          machine.wait_until_succeeds("osctl ct exec #{ctid} rc-service networking status")
          machine.wait_until_succeeds("ping -c 1 192.0.2.#{20 + index}")
          machine.all_succeed("osctl ct stop #{ctid}", "osctl ct del --prune #{ctid}")
        end

        # New userspace must start ordinary guests on the still-running
        # predecessor kernel too, including 6.12 without the optional new
        # tracing/securityfs sources and 6.18 with them already present.
        machine.all_succeed(
          "osctl ct new --distribution alpine afterupgrade",
          "osctl ct unset start-menu afterupgrade",
          "osctl ct netif new routed afterupgrade eth0",
          "osctl ct netif ip add afterupgrade eth0 192.0.2.12/32",
          "osctl ct start afterupgrade",
        )
        machine.wait_until_succeeds("osctl ct exec afterupgrade rc-service networking status")
        machine.wait_until_succeeds("ping -c 1 192.0.2.12")
        machine.all_succeed(
          "osctl ct exec afterupgrade sh -c 'echo post-upgrade-data > /root/retained'",
          "osctl ct restart afterupgrade",
        )
        machine.wait_until_succeeds("osctl ct exec afterupgrade rc-service networking status")
        machine.wait_until_succeeds("ping -c 1 192.0.2.12")
        machine.all_succeed(
          "osctl ct exec afterupgrade grep -Fx post-upgrade-data /root/retained",
          "osctl ct stop afterupgrade",
          "osctl ct del --prune afterupgrade",
        )
        expect(machine.succeeds('uname -r')[1].strip).to eq(before_kernel)
        expect(machine.succeeds('cat /proc/sys/kernel/random/boot_id')[1].strip).to eq(before_boot)

        # Restart the actual predecessor-created running workloads, not only
        # afterupgrade. Convert their test init back to the ordinary guest init.
        snapshots.each do |ctid, saved|
          machine.all_succeed("osctl ct stop #{ctid}", "osctl ct unset init-cmd #{ctid}", "osctl ct start #{ctid}")
          machine.wait_until_succeeds("osctl ct exec #{ctid} rc-service networking status")
          machine.wait_until_succeeds("ping -c 1 #{saved.fetch(:address)}")
          machine.succeeds("osctl ct exec #{ctid} grep -Fx retained-data /upgrade/data")
          machine.succeeds("osctl ct restart #{ctid}")
          machine.wait_until_succeeds("osctl ct exec #{ctid} rc-service networking status")
          machine.wait_until_succeeds("ping -c 1 #{saved.fetch(:address)}")
          machine.succeeds("osctl ct exec #{ctid} grep -Fx retained-data /upgrade/data")
        end

        # Containers created by the predecessor must still stop and delete cleanly.
        snapshots.each do |ctid, saved|
          machine.all_succeed(
            "osctl ct stop #{ctid}",
            "test ! -e /sys/class/net/#{saved.fetch(:veth)}",
          )
          info = machine.osctl_json("ct show #{ctid}")
          expect(info.fetch('state')).to eq('stopped')
          expect(info.fetch('recovery_tainted')).to be(false)
          machine.succeeds("osctl ct del --prune #{ctid}")
        end
      '';
    }
  )
  (
    (builtins.removeAttrs args [ "cgroupVersion" ])
    // {
      inherit system;
      pkgs = previous.inputs.nixpkgs.outPath;
      testFramework = previous.lib.testFramework;
      configuration =
        if configuration == null then null else import (previous.outPath + "/${configuration}");
    }
  )
