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
          pid = status.match(/\(pid (\d+)\)/).captures.first
          [pid, machine.succeeds("awk '{print $22}' /proc/#{pid}/stat")[1].strip]
        end
        before_daemon = daemon_identity.call
        machine.push_file('${consoleClient}', '/root/upgrade-console.rb')

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
          snapshots.each do |ctid, saved|
            info = machine.osctl_json("ct show #{ctid}")
            expect(info.fetch('state')).to eq('running')
            expect(info.fetch('init_pid').to_i).to eq(saved.fetch(:init))
            init = saved.fetch(:init)
            expect(machine.succeeds("awk '{print $22}' /proc/#{init}/stat")[1]).to eq(saved.fetch(:init_start))
            expect(machine.succeeds("cat /proc/#{init}/cgroup")[1]).to eq(saved.fetch(:cgroup))
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
          machine.wait_for_osctl_pool('tank')
          expect(daemon_identity.call).not_to eq(prior_daemon)
          expect(private_mounts.call).to eq(adopted_mounts)
          assert_retained.call
        end

        # The transient attach path must work on an inherited stopped CT,
        # without starting it or losing its persistent root filesystem.
        machine.all_succeed(
          'osctl ct exec -rn previouslyrun ping -c 1 255.255.255.254',
          'osctl ct runscript -rn previouslyrun ${stoppedNetwork}',
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
