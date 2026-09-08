# Run explicitly with VPSADMINOS_UPGRADE_FROM pointing to the unmodified
# predecessor source. Use its native machine definition to boot old userspace;
# the candidate is activated in that same VM, without rebooting or draining.
# Use the predecessor's test-runner package and set TEST_RUNNER_REPO_ROOT
# to this candidate. Its runner and guest must use the same shell transport;
# the already-running test shell is retained across generation activation.
args:
let
  from = builtins.getEnv "VPSADMINOS_UPGRADE_FROM";
  legacy =
    if from == "" then
      throw "set VPSADMINOS_UPGRADE_FROM to the predecessor source"
    else
      builtins.toPath from;
in
import (legacy + "/tests/make-test.nix") (
  { pkgs }:
  let
    nextSystem =
      (import ../../../os (
        {
          importedPkgs = pkgs;
          system = pkgs.system;
          configuration = null;
          modules = [
            ../../configs/vpsadminos/base.nix
            ../../configs/vpsadminos/pool-tank.nix
            {
              system.vpsadminos.enableUnstable = true;
              osctl.test-shell.shells = 1;
            }
          ];
        }
        // (pkgs.vpsadminosTestFrameworkInputs or { })
      )).config.system.build.toplevel;

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
    name = "osctld-upgrade";
    description = "Activate the candidate over running predecessor containers";
    tags = [ ];

    machine = import ../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config.system.extraDependencies = [ nextSystem ];
    };

    testScript = ''
      require 'json'
      require 'shellwords'

      machine.start
      machine.wait_for_osctl_pool('tank')
      machine.wait_until_online
      before_kernel = machine.succeeds('uname -r')[1].strip
      before_boot = machine.succeeds('cat /proc/sys/kernel/random/boot_id')[1].strip
      before_bpffs = machine.succeeds('stat -c %d:%i /sys/fs/bpf')[1].strip
      daemon_identity = lambda do
        status = machine.succeeds('sv status osctld')[1]
        pid = status.match(/\(pid (\d+)\)/).captures.first
        [pid, machine.succeeds("awk '{print $22}' /proc/#{pid}/stat")[1].strip]
      end
      before_daemon = daemon_identity.call
      machine.push_file('${consoleClient}', '/root/upgrade-console.rb')

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

      # Old untagged lifecycle callbacks must still complete cleanup.
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
) (args // { configuration = null; })
