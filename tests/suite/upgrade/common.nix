# Shared native test; each named case pins its predecessor generations.
{
  name,
  revision,
  kernelPrefix,
  configuration ? null,
  activated ? null,
}:
args:
let
  previous = builtins.getFlake "github:vpsfreecz/vpsadminos/${revision}";
  current = builtins.getFlake (toString ../../..);
  system = args.system or builtins.currentSystem;
  cgroupVersion = args.cgroupVersion or 2;
  guestPolicies = args.guestPolicies or false;
  cgroupConfig.boot.enableUnifiedCgroupHierarchy = cgroupVersion == 2;
  activatedSource =
    if activated == null then
      null
    else
      builtins.getFlake "github:vpsfreecz/vpsadminos/${activated.revision}";
  activatedSystem =
    if activated == null then
      null
    else
      (activatedSource.lib.vpsadminosSystem {
        inherit system;
        configuration =
          if (activated.configuration or null) == null then
            null
          else
            import (activatedSource.outPath + "/${activated.configuration}");
        modules = [
          (activatedSource.outPath + "/tests/configs/vpsadminos/base.nix")
          (activatedSource.outPath + "/tests/configs/vpsadminos/pool-tank.nix")
          {
            disabledModules = [ (activatedSource.outPath + "/os/modules/osctl/test-shell.nix") ];
            imports = [ ../../../os/modules/osctl/test-shell.nix ];
            osctl.test-shell.shells = 1;
          }
          cgroupConfig
        ];
      }).config.system.build.toplevel;
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
        (exec /sbin/upgrade-busybox tcpsvd 0.0.0.0 8081 /sbin/upgrade-busybox cat > /upgrade/tcp.log 2>&1) &
        echo $! > /upgrade/tcp.pid
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

      streamClient = pkgs.writeText "upgrade-tcp-stream.rb" ''
        require 'json'
        require 'socket'
        require 'timeout'

        address, prefix = ARGV
        socket = nil
        begin
          # Connect exactly once. Reconnection would hide an interrupted flow.
          socket = Socket.tcp(address, 8081, connect_timeout: 30)
          port = socket.local_address.ip_port
          sequence = 0
          until File.exist?("#{prefix}.stop")
            message = "#{sequence}\n"
            Timeout.timeout(30) do
              socket.write(message)
              raise 'sequence mismatch' unless socket.readline == message
            end
            sequence += 1
            File.write("#{prefix}.new", JSON.generate(sequence:, port:))
            File.rename("#{prefix}.new", "#{prefix}.progress")
            sleep(0.1)
          end
          File.write("#{prefix}.done", sequence.to_s)
        rescue StandardError => e
          File.write("#{prefix}.error", "#{e.class}: #{e.message}")
          raise
        ensure
          socket&.close
        end
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
      name =
        "upgrade-${name}"
        + (if guestPolicies then "-guests" else "")
        + (if cgroupVersion == 1 then "-v1" else "");
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
          system.extraDependencies = [
            nextSystem
          ]
          ++ (if activatedSystem == null then [ ] else [ activatedSystem ]);
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
        booted_system = machine.succeeds('readlink -f /run/booted-system')[1].strip
        expect(machine.succeeds('readlink -f /run/current-system')[1].strip).to eq(booted_system)
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
        machine.push_file('${consoleClient}', '/root/upgrade-console.rb')
        machine.push_file('${stoppedNetwork}', '/root/upgrade-stopped-network')
        machine.push_file('${streamClient}', '/root/upgrade-tcp-stream.rb')
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
        probe_sequence = 0
        run_resource_probe = lambda do |mode|
          probe_sequence += 1
          prefix = "/run/upgrade-probe-#{probe_sequence}-#{mode}"
          # Ruby loads inside the limited CT cgroup before the C probe starts.
          # The observed predecessor bootstrap can exceed 40s at 25% CPU. Keep
          # the C workload's own 30s alarm and budget bootstrap/exit separately.
          machine.succeeds("(set +e; timeout 120 osctl ct exec limited /bin/upgrade-resource-probe #{mode} > #{prefix}.log 2>&1; echo $? > #{prefix}.status) < /dev/null > #{prefix}.launcher 2>&1 &")
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 150
          loop do
            status, = machine.execute("test -f #{prefix}.status", timeout: 10)
            break if status == 0
            fail "resource probe status missing: #{prefix}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

            machine.execute(<<~SH, timeout: 15)
              set +e
              date -Ins
              cat /proc/uptime /proc/loadavg
              cat #{prefix}.log
              for pid in $(pgrep -f 'osctld-ct-runner$|^osctld: tank:limited runner:|^/bin/upgrade-resource-probe'); do
                echo "=== probe process $pid ==="
                ps -p "$pid" -o pid,ppid,etimes,time,stat,wchan:24,args
                cat /proc/$pid/stat /proc/$pid/schedstat /proc/$pid/cgroup
                grep -E '^(State|VmRSS|Sig|Cpus_allowed_list)' /proc/$pid/status
                cat /proc/$pid/syscall /proc/$pid/stack
              done
              for root in /run/osctl/cgroup /sys/fs/cgroup; do
                test -d "$root" || continue
                find "$root" -path '*user.limited/ct.limited/cpu.stat' -o -path '*user.limited/ct.limited/memory.events' -o -path '*user.limited/ct.limited/memory.oom_control' | while read file; do
                  echo "=== $file ==="
                  cat "$file"
                done
              done
              true
            SH
            sleep(5)
          end
          output = machine.succeeds("cat #{prefix}.log")[1]
          expect(machine.succeeds("cat #{prefix}.status")[1].strip).to eq('0')
          expect(output).to include("probe_phase=#{mode} ", 'probe_phase=complete ')
          if cgroup_version == 1 && %w[pids memory].include?(mode)
            key = mode == 'pids' ? 'max' : 'oom_kill'
            event = output.match(/probe_event=#{key} before=(\d+) after=(\d+)/)
            expect(event).not_to be_nil
            expect(Integer(event[2])).to be > Integer(event[1])
          end
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
          run_resource_probe.call('cpu')
          expect(counter.call('cpu.stat', 'nr_throttled')).to be > throttled
          # v1 local counters are measured inside the actual probe leaf before
          # helper teardown removes it. v2 events propagate to the parent.
          pids_denied = counter.call('pids.events', 'max') if cgroup_version == 2
          run_resource_probe.call('pids')
          expect(counter.call('pids.events', 'max')).to be > pids_denied if cgroup_version == 2
          memory_denied = counter.call('memory.events', 'oom_kill') if cgroup_version == 2
          run_resource_probe.call('memory')
          expect(counter.call('memory.events', 'oom_kill')).to be > memory_denied if cgroup_version == 2
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
          # The predecessor bpftool's single-link query prints valid data but
          # returns stale errno. Its full listing has a proper success path.
          all_links = JSON.parse(machine.succeeds('bpftool -j -f link show')[1])
          links = pins.map do |pin|
            matches = all_links.select { |link| link.fetch('pinned', []).include?(pin) }
            expect(matches.length).to eq(1)
            link = matches.first
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

        guest_snapshots = {}
        ${
          if !guestPolicies then
            ""
          else
            ''
              # Real guest services, not replacement init or host-applied guest
              # networking. Pin the older NixOS images used by resolver tests.
              [
                ['nmguest', 'fedora', '44', 'minimal', '192.0.2.30'],
                ['nixold', 'nixos', '22.11', 'minimal', '192.0.2.31'],
                ['niximpermanent', 'nixos', '24.05', 'impermanence', '192.0.2.32'],
              ].each do |ctid, distribution, version, variant, address|
                machine.all_succeed(
                  "osctl ct new --distribution #{distribution} --version #{version} --variant #{variant} #{ctid}",
                  "osctl ct unset start-menu #{ctid}",
                  "osctl ct netif new routed #{ctid} eth0",
                  "osctl ct netif ip add #{ctid} eth0 #{address}/32",
                  "osctl ct set dns-resolver #{ctid} 192.0.2.53",
                  "osctl ct start #{ctid}",
                )
                machine.wait_until_succeeds("ping -c 1 #{address}")
                machine.succeeds("osctl ct exec #{ctid} systemctl is-system-running --wait")
                if distribution == 'fedora'
                  machine.all_succeed(
                    "osctl ct exec #{ctid} systemctl is-active NetworkManager.service",
                    "osctl ct exec #{ctid} sed -i '/^dns=none$/d' /etc/NetworkManager/conf.d/vpsadminos.conf",
                    "osctl ct exec #{ctid} nmcli general reload conf,dns-rc",
                    "osctl ct exec #{ctid} nmcli connection modify eth0 ipv4.dns 10.0.2.3 ipv4.ignore-auto-dns yes",
                    "osctl ct exec #{ctid} nmcli device reapply eth0",
                    "osctl ct set dns-resolver #{ctid} 192.0.2.53",
                  )
                else
                  expect(machine.succeeds("osctl ct exec #{ctid} nixos-version")[1].strip).to start_with(version)
                  machine.succeeds("osctl ct exec #{ctid} systemctl is-active networking-setup.service")
                end
                machine.succeeds("osctl ct exec #{ctid} grep -Fx 'nameserver 192.0.2.53' /etc/resolv.conf")
                info = machine.osctl_json("ct show #{ctid}")
                expect(info.fetch('version')).to eq(version)
                if variant == 'impermanence'
                  expect(info.fetch('impermanence')).to be(true)
                  expect(info.fetch('boot_dataset')).not_to eq(info.fetch('dataset'))
                  machine.all_succeed(
                    "osctl ct exec #{ctid} mountpoint -q /persistent",
                    "osctl ct exec #{ctid} sh -c 'echo inherited-persistent > /persistent/upgrade-retained; echo inherited-ephemeral > /upgrade-ephemeral'",
                  )
                else
                  machine.succeeds("osctl ct exec #{ctid} sh -c 'echo inherited-persistent > /root/upgrade-retained'")
                end
                init = info.fetch('init_pid')
                guest_snapshots[ctid] = {
                  distribution:, address:, init:,
                  impermanent: variant == 'impermanence',
                  boot_dataset: info.fetch('boot_dataset'),
                  init_start: machine.succeeds("awk '{print $22}' /proc/#{init}/stat")[1],
                  generation: distribution == 'nixos' ? machine.succeeds("osctl ct exec #{ctid} readlink /run/current-system")[1] : nil,
                  nm_pid: distribution == 'fedora' ? machine.succeeds("osctl ct exec #{ctid} systemctl show -p MainPID --value NetworkManager.service")[1] : nil,
                }
              end
            ''
        }

        snapshots = {}
        create_workload = lambda do |ctid, address, create: true, start: true|
          if create
            machine.all_succeed(
              "osctl ct new --distribution alpine #{ctid}",
              "osctl ct unset start-menu #{ctid}",
              "osctl ct netif new routed #{ctid} eth0",
              "osctl ct netif ip add #{ctid} eth0 #{address}/32",
              "osctl ct mount #{ctid}",
            )
          end
          info = machine.osctl_json("ct show #{ctid}")
          # The minimal image does not install an HTTP server. Supply the
          # workload explicitly, not as an assumed guest package or policy.
          machine.push_file('${pkgs.pkgsStatic.busybox}/bin/busybox', "#{info.fetch('rootfs')}/sbin/upgrade-busybox", preserve: true)
          machine.push_file('${workload}', "#{info.fetch('rootfs')}/sbin/upgrade-workload", preserve: true)
          machine.succeeds("osctl ct set init-cmd #{ctid} /sbin/upgrade-workload")
          unless start
            machine.succeeds("echo activated-generation-data > #{Shellwords.escape(info.fetch('rootfs'))}/activated-generation-data")
            next
          end
          machine.succeeds("osctl ct start #{ctid}")
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
          prefix = "/run/upgrade-stream-#{ctid}"
          machine.succeeds("ruby /root/upgrade-tcp-stream.rb #{address} #{prefix} > #{prefix}.log 2>&1 & echo $! > #{prefix}.pid")
          machine.wait_until_succeeds("test -s #{prefix}.progress")
          stream = JSON.parse(machine.succeeds("cat #{prefix}.progress")[1])
          stream_pid = machine.succeeds("cat #{prefix}.pid")[1].strip
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
            tcp: machine.succeeds("osctl ct exec #{ctid} sh -c 'cat /proc/$(cat /upgrade/tcp.pid)/stat'")[1].split.values_at(0, 21),
            stream_prefix: prefix,
            stream_port: stream.fetch('port'),
            stream_pid:,
            stream_start: machine.succeeds("awk '{print $22}' /proc/#{stream_pid}/stat")[1],
          }
        end

        assert_retained = lambda do
          guest_snapshots.each do |ctid, saved|
            info = machine.osctl_json("ct show #{ctid}")
            expect(info.fetch('init_pid')).to eq(saved.fetch(:init))
            expect(info.fetch('dns_resolvers')).to eq(['192.0.2.53'])
            expect(machine.succeeds("awk '{print $22}' /proc/#{saved.fetch(:init)}/stat")[1]).to eq(saved.fetch(:init_start))
            expect(info.fetch('boot_dataset')).to eq(saved.fetch(:boot_dataset))
            marker = saved.fetch(:impermanent) ? '/persistent/upgrade-retained' : '/root/upgrade-retained'
            machine.succeeds("osctl ct exec #{ctid} grep -Fx inherited-persistent #{marker}")
            if saved.fetch(:impermanent)
              machine.succeeds("osctl ct exec #{ctid} grep -Fx inherited-ephemeral /upgrade-ephemeral")
            end
            machine.succeeds("osctl ct exec #{ctid} systemctl is-system-running --wait")
            machine.succeeds("osctl ct exec #{ctid} grep -Fx 'nameserver 192.0.2.53' /etc/resolv.conf")
            machine.succeeds("ping -c 1 #{saved.fetch(:address)}")
            if saved.fetch(:distribution) == 'nixos'
              expect(machine.succeeds("osctl ct exec #{ctid} readlink /run/current-system")[1]).to eq(saved.fetch(:generation))
              machine.succeeds("osctl ct exec #{ctid} systemctl is-active networking-setup.service")
            else
              expect(machine.succeeds("osctl ct exec #{ctid} systemctl show -p MainPID --value NetworkManager.service")[1]).to eq(saved.fetch(:nm_pid))
            end
          end
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
            tcp = machine.succeeds("osctl ct exec #{ctid} sh -c 'cat /proc/$(cat /upgrade/tcp.pid)/stat'")[1].split.values_at(0, 21)
            expect(tcp).to eq(saved.fetch(:tcp))
            prefix = saved.fetch(:stream_prefix)
            machine.succeeds("test ! -e #{prefix}.error && kill -0 #{saved.fetch(:stream_pid)}")
            expect(machine.succeeds("awk '{print $22}' /proc/#{saved.fetch(:stream_pid)}/stat")[1]).to eq(saved.fetch(:stream_start))
            stream = JSON.parse(machine.succeeds("cat #{prefix}.progress")[1])
            expect(stream.fetch('port')).to eq(saved.fetch(:stream_port))
            machine.all_succeed(
              "osctl ct exec #{ctid} grep -Fx retained-data /upgrade/data",
              "ruby /root/upgrade-console.rb #{ctid} after-upgrade",
              "ping -c 1 #{saved.fetch(:address)}",
              "curl --fail --max-time 10 http://#{saved.fetch(:address)}:8080/data | grep -Fx retained-data",
            )
          end
        end
        %w[upgrade1 upgrade2].each_with_index do |ctid, index|
          create_workload.call(ctid, "192.0.2.#{10 + index}")
        end

        activate_generation = lambda do |target|
          prior_daemon = daemon_identity.call
          sequences = snapshots.transform_values do |saved|
            JSON.parse(machine.succeeds("cat #{saved.fetch(:stream_prefix)}.progress")[1]).fetch('sequence')
          end
          machine.succeeds("#{target}/bin/switch-to-configuration test", timeout: 300)
          # Keep the same connections transferring ordered data during the
          # activation, not just fresh connections before and afterwards.
          snapshots.each do |ctid, saved|
            prefix = saved.fetch(:stream_prefix)
            machine.succeeds("test ! -e #{prefix}.error")
            stream = JSON.parse(machine.succeeds("cat #{prefix}.progress")[1])
            expect(stream.fetch('sequence')).to be > sequences.fetch(ctid)
            expect(stream.fetch('port')).to eq(saved.fetch(:stream_port))
          end
          machine.wait_for_osctl_pool('tank')
          expect(machine.succeeds('uname -r')[1].strip).to eq(before_kernel)
          expect(machine.succeeds('cat /proc/sys/kernel/random/boot_id')[1].strip).to eq(before_boot)
          expect(machine.succeeds('readlink -f /run/booted-system')[1].strip).to eq(booted_system)
          expect(machine.succeeds('readlink -f /run/current-system')[1].strip).to eq(target)
          expect(daemon_identity.call).not_to eq(prior_daemon)
          expect(machine.succeeds('stat -c %d:%i /run/osctl/bpf')[1].strip).to eq(before_bpffs)
          expect(machine.succeeds('stat -f -c %T /run/osctl/bpf')[1].strip).to eq('bpf_fs')
          assert_retained.call
        end

        ${
          if activatedSystem == null then
            ""
          else
            ''
              # Booted B remains unchanged while state from B and activated A
              # coexist. The named case fixes A's revision; no live inventory.
              activate_generation.call('${activatedSystem}')
              expect('${activatedSystem}').not_to eq(booted_system)
              # This frozen userspace cannot start new CTs after the v1 live
              # switch: its LXC requires the missing /run/osctl/cgroup. Do not
              # repair A in the fixture. Retain A-created stopped state and
              # require T to start it, alongside the continuously running B CTs.
              create_workload.call('activegeneration', '192.0.2.13', start: false)
              assert_limits.call(25, 64)
            ''
        }
        activate_generation.call('${nextSystem}')

        ${
          if activatedSystem == null then
            ""
          else
            ''
              create_workload.call('activegeneration', '192.0.2.13', create: false)
              machine.succeeds('osctl ct exec activegeneration grep -Fx activated-generation-data /activated-generation-data')
              assert_retained.call
            ''
        }

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

        guest_snapshots.each do |ctid, saved|
          if saved.fetch(:distribution) == 'fedora'
            # Configured resolver intent must survive an actual guest refresh,
            # not just an unchanged file immediately after host activation.
            machine.succeeds("osctl ct exec #{ctid} nmcli general reload dns-rc")
            machine.succeeds("osctl ct exec #{ctid} grep -Fx 'nameserver 192.0.2.53' /etc/resolv.conf")
          end
          machine.succeeds("osctl ct set dns-resolver #{ctid} 192.0.2.54")
          machine.succeeds("osctl ct exec #{ctid} nmcli general reload dns-rc") if saved.fetch(:distribution) == 'fedora'
          machine.succeeds("osctl ct exec #{ctid} grep -Fx 'nameserver 192.0.2.54' /etc/resolv.conf")
          machine.succeeds("osctl ct unset dns-resolver #{ctid}")
          expect(machine.osctl_json("ct show #{ctid}").fetch('dns_resolvers')).to be_nil
          if saved.fetch(:distribution) == 'fedora'
            machine.succeeds("osctl ct exec #{ctid} nmcli general reload dns-rc")
            machine.succeeds("osctl ct exec #{ctid} grep -Fx 'nameserver 10.0.2.3' /etc/resolv.conf")
            machine.fails("osctl ct exec #{ctid} test -e /etc/NetworkManager/conf.d/10-osctl-dns.conf")
          end
          machine.succeeds("osctl ct set dns-resolver #{ctid} 192.0.2.53")
        end
        assert_retained.call

        # Running helpers on inherited CTs have different contracts: attach
        # and runscript enter the guest, while ct su is an unprivileged host
        # shell for this CT. Do not count one path as proof of the others.
        machine.succeeds('echo host-shell > /run/upgrade-host-only; chmod 444 /run/upgrade-host-only')
        snapshots.each_key do |ctid|
          verify_helper_mounts = lambda do |operation|
            before = snapshots.fetch(ctid).fetch(:mounts)
            after = machine.succeeds("cat /proc/#{snapshots.fetch(ctid).fetch(:init)}/mountinfo")[1]
            expect(after).to eq(before), "#{operation} changed inherited #{ctid} mounts:\n#{after}"
          end
          attach = 'set -e; test "$(id -u)" = 0; test ! -e /run/upgrade-host-only; grep -Fx retained-data /upgrade/data; exit 0'
          machine.succeeds("printf '%s\\n' #{Shellwords.escape(attach)} | timeout 30 osctl ct attach #{ctid}", timeout: 60)
          verify_helper_mounts.call('ct attach')
          su = 'set -e; test "$(id -u)" != 0; grep -Fx host-shell /run/upgrade-host-only; test -z "$OSCTL_RUN_ID"; exit 0'
          machine.succeeds("printf '%s\\n' #{Shellwords.escape(su)} | timeout 30 osctl ct su #{ctid}", timeout: 60)
          verify_helper_mounts.call('ct su')
          script = "#!/bin/sh\nset -eu\ntest \"$(id -u)\" = 0\ngrep -Fx retained-data /upgrade/data\necho helper-data > /upgrade/helper-data\n"
          machine.succeeds("printf %s #{Shellwords.escape(script)} | timeout 30 osctl ct runscript #{ctid} -", timeout: 60)
          verify_helper_mounts.call('ct runscript')
          expect(machine.succeeds("osctl ct cat #{ctid} /upgrade/helper-data")[1].strip).to eq('helper-data')
          verify_helper_mounts.call('ct cat')
        end
        assert_retained.call

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
          snapshots.each_key do |ctid|
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
          prefix = saved.fetch(:stream_prefix)
          machine.succeeds("touch #{prefix}.stop")
          machine.wait_until_succeeds("test -s #{prefix}.done")
          machine.succeeds("test ! -e #{prefix}.error")
          machine.all_succeed("osctl ct stop #{ctid}", "osctl ct unset init-cmd #{ctid}", "osctl ct start #{ctid}")
          machine.wait_until_succeeds("osctl ct exec #{ctid} rc-service networking status")
          machine.wait_until_succeeds("ping -c 1 #{saved.fetch(:address)}")
          machine.succeeds("osctl ct exec #{ctid} grep -Fx retained-data /upgrade/data")
          machine.succeeds("osctl ct restart #{ctid}")
          machine.wait_until_succeeds("osctl ct exec #{ctid} rc-service networking status")
          machine.wait_until_succeeds("ping -c 1 #{saved.fetch(:address)}")
          machine.succeeds("osctl ct exec #{ctid} grep -Fx retained-data /upgrade/data")
        end

        # Exercise the guest's own reboot command, not another host stop/start.
        # The old host kernel and boot generation must not change with it.
        snapshots.each do |ctid, saved|
          old_init = machine.osctl_json("ct show #{ctid}").fetch('init_pid')
          old_identity = machine.succeeds("awk '{print $22}' /proc/#{old_init}/stat")[1].strip
          machine.succeeds("osctl ct exec #{ctid} sh -c '(sleep 2; reboot) >/root/upgrade-reboot.log 2>&1 </dev/null &'")
          machine.wait_until_succeeds("test ! -e /proc/#{old_init}/stat || test \"$(awk '{print $22}' /proc/#{old_init}/stat)\" != #{old_identity}", timeout: 120)
          machine.wait_until_succeeds("osctl ct exec #{ctid} rc-service networking status", timeout: 180)
          machine.wait_until_succeeds("ping -c 1 #{saved.fetch(:address)}")
          info = machine.osctl_json("ct show #{ctid}")
          expect(info.fetch('state')).to eq('running')
          new_identity = machine.succeeds("awk '{print $22}' /proc/#{info.fetch('init_pid')}/stat")[1].strip
          expect([info.fetch('init_pid'), new_identity]).not_to eq([old_init, old_identity])
          machine.succeeds("osctl ct exec #{ctid} grep -Fx retained-data /upgrade/data")
          expect(info.fetch('recovery_tainted')).to be(false)
          expect(machine.succeeds('uname -r')[1].strip).to eq(before_kernel)
          expect(machine.succeeds('cat /proc/sys/kernel/random/boot_id')[1].strip).to eq(before_boot)
        end

        guest_snapshots.each do |ctid, saved|
          machine.succeeds("osctl ct restart #{ctid}")
          machine.wait_until_succeeds("ping -c 1 #{saved.fetch(:address)}")
          machine.succeeds("osctl ct exec #{ctid} systemctl is-system-running --wait")
          machine.succeeds("osctl ct exec #{ctid} grep -Fx 'nameserver 192.0.2.53' /etc/resolv.conf")
          marker = saved.fetch(:impermanent) ? '/persistent/upgrade-retained' : '/root/upgrade-retained'
          machine.succeeds("osctl ct exec #{ctid} grep -Fx inherited-persistent #{marker}")
          if saved.fetch(:impermanent)
            machine.succeeds("osctl ct exec #{ctid} test ! -e /upgrade-ephemeral")
            expect(machine.osctl_json("ct show #{ctid}").fetch('boot_dataset')).not_to eq(saved.fetch(:boot_dataset))
            machine.wait_until_succeeds("! zfs list -H #{Shellwords.escape(saved.fetch(:boot_dataset))}", timeout: 120)
          end
          if saved.fetch(:generation)
            expect(machine.succeeds("osctl ct exec #{ctid} readlink /run/current-system")[1]).to eq(saved.fetch(:generation))
          end
          machine.all_succeed("osctl ct stop #{ctid}", "osctl ct del --prune #{ctid}")
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
    (builtins.removeAttrs args [
      "cgroupVersion"
      "guestPolicies"
    ])
    // {
      inherit system;
      pkgs = previous.inputs.nixpkgs.outPath;
      testFramework = previous.lib.testFramework;
      configuration =
        if configuration == null then null else import (previous.outPath + "/${configuration}");
    }
  )
