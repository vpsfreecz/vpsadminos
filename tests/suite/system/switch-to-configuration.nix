import ../../make-test.nix (
  { pkgs }:
  let
    triggerA = pkgs.writeText "runit-restart-trigger-a" "a";
    triggerB = pkgs.writeText "runit-restart-trigger-b" "b";
    triggerC = pkgs.writeText "runit-restart-trigger-c" "c";
    nodectldStateDir = "/run/nodectld-switch-test";
    nodectldSocket = "/run/nodectl/nodectld.sock";
    nodectldClient = pkgs.writeScript "nodectld-switch-test-client" ''
      #!${pkgs.ruby}/bin/ruby
      require 'json'
      require 'socket'

      socket = UNIXSocket.new(${builtins.toJSON nodectldSocket})
      greeting = JSON.parse(socket.gets)
      raise 'missing nodectld protocol version' unless greeting['version']

      socket.puts(JSON.generate(command: ARGV.fetch(0), params: {}))
      reply = JSON.parse(socket.gets)
      exit(reply['status'] == 'ok' ? 0 : 1)
    '';
    nodectldHook = pkgs.writeScript "nodectld-switch-test-hook" ''
      #!${pkgs.ruby}/bin/ruby
      require 'fileutils'
      require 'json'

      def with_pause_lock(path)
        FileUtils.mkdir_p(File.dirname(path))
        File.open(path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end

      def marker_state(path, current_boot)
        cfg = JSON.parse(File.read(path))
        return :owned unless cfg.is_a?(Hash) && cfg['boot_id'].is_a?(String)
        return :stale unless cfg['boot_id'] == current_boot

        cfg['schema'] == 1 && cfg['reason'] == 'osctld-restart' \
          ? :ordinary \
          : :owned
      rescue Errno::ENOENT
        :absent
      rescue JSON::ParserError
        :owned
      end

      command = ARGV.fetch(0)
      pause_path = '/run/osctl/nodectld-upgrade-pause.json'
      pause_lock_path = "#{pause_path}.lock"
      current_boot = File.read('/proc/sys/kernel/random/boot_id').strip
      tmp = nil
      begin
        if command == 'resume'
          state = with_pause_lock(pause_lock_path) do
            marker_state(pause_path, current_boot)
          end
          exit(0) if state == :owned
        end

        if command == 'pause'
          with_pause_lock(pause_lock_path) do
            state = marker_state(pause_path, current_boot)
            if %i[absent stale].include?(state)
              cfg = {
                'schema' => 1,
                'boot_id' => current_boot,
                'created_at' => Time.now.to_f,
                'reason' => 'osctld-restart',
              }
              FileUtils.mkdir_p(File.dirname(pause_path))
              tmp = "#{pause_path}.#{$$}.new"
              File.write(tmp, JSON.pretty_generate(cfg))
              File.chmod(0o600, tmp)
              File.rename(tmp, pause_path)
            end
          end
        end

        succeeded = system(${builtins.toJSON nodectldClient}, command)
        if succeeded && command == 'resume'
          with_pause_lock(pause_lock_path) do
            if marker_state(pause_path, current_boot) == :ordinary
              File.unlink(pause_path)
            end
          end
        end
        exit(succeeded ? 0 : 1)
      ensure
        File.unlink(tmp) if tmp && File.exist?(tmp)
      end
    '';
    nodectldServer = pkgs.writeScript "nodectld-switch-test-server" ''
      #!${pkgs.ruby}/bin/ruby
      require 'fileutils'
      require 'json'
      require 'socket'

      state_dir = ${builtins.toJSON nodectldStateDir}
      socket_path = ${builtins.toJSON nodectldSocket}
      pause_path = '/run/osctl/nodectld-upgrade-pause.json'
      boot_id_path = '/proc/sys/kernel/random/boot_id'
      FileUtils.mkdir_p(state_dir)
      FileUtils.mkdir_p(File.dirname(socket_path))
      File.unlink(socket_path) if File.exist?(socket_path)
      File.open(File.join(state_dir, 'events'), 'a') do |f|
        f.puts("start pid=#{Process.pid}")
      end
      File.write(File.join(state_dir, 'pid'), "#{Process.pid}\n")

      begin
        pause_cfg = JSON.parse(File.read(pause_path))
        if pause_cfg['schema'] == 1 \
            && pause_cfg['boot_id'] == File.read(boot_id_path).strip
          File.write(File.join(state_dir, 'paused'), "1\n")
        end
      rescue Errno::ENOENT, JSON::ParserError
        nil
      end

      server = UNIXServer.new(socket_path)
      stopping = false
      trap('TERM') do
        stopping = true
        server.close
      rescue IOError
        nil
      end

      loop do
        client = server.accept
        client.puts(JSON.generate(version: 1))
        request = JSON.parse(client.gets)
        command = request.fetch('command')
        File.open(File.join(state_dir, 'events'), 'a') { |f| f.puts(command) }
        response = nil
        if command == 'pause' && File.exist?(File.join(state_dir, 'fail-pause'))
          client.puts(JSON.generate(status: 'failed', error: 'injected pause failure'))
          next
        elsif command == 'pause'
          File.write(File.join(state_dir, 'paused'), "1\n")
        elsif command == 'resume'
          FileUtils.rm_f(File.join(state_dir, 'paused'))
        elsif command == 'status'
          response = {
            state: {
              pause: File.exist?(File.join(state_dir, 'paused')),
              restart_barrier: File.exist?(pause_path),
            },
            queues: {
              vps: { workers: {} },
            },
            subprocesses: {},
          }
        end
        client.puts(JSON.generate(status: 'ok', response: response))
      rescue Errno::EPIPE, Errno::ECONNRESET
        nil
      rescue IOError, Errno::EBADF
        break if stopping

        raise
      ensure
        client&.close
      end
      File.open(File.join(state_dir, 'events'), 'a') { |f| f.puts('stop') }
    '';
    nodectldTestService = trigger: {
      runit.services.nodectld = {
        run = ''
          install -d -m 755 /run/osctl/hooks/daemon
          for hook in pre-stop post-resume; do
            command=pause
            [ "$hook" != post-resume ] || command=resume
            cat > "/run/osctl/hooks/daemon/$hook" <<EOF
          #!${pkgs.runtimeShell}
          exec ${nodectldHook} $command
          EOF
            chmod 500 "/run/osctl/hooks/daemon/$hook"
          done
          exec ${nodectldServer}
        '';
        restartTriggers = [ trigger ];
      };
    };
    handoffBoundaryService = trigger: {
      runit.services.handoff-boundary-test = {
        run = ''
          state_dir=/run/handoff-boundary-test
          install -d -m 755 "$state_dir"
          rm -f "$state_dir/stopping" "$state_dir/release"
          trap '
            touch "$state_dir/stopping"
            while [ ! -e "$state_dir/release" ]; do
              sleep 0.1
            done
            exit 0
          ' TERM
          while true; do
            sleep 3600 &
            wait $! || true
          done
        '';
        restartTriggers = [ trigger ];
      };
    };
    removedModule = "bonding";
    addedModule = "macvlan";
    keptModule = "8021q";
    failedModule = "vpsadminos_missing_test_module";
    legacySource = pkgs.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "vpsadminos";
      rev = "fc6c9fe67d7d365f26a5ab286625fd55fd5f79e1";
      hash = "sha256-NGEgkL1PyYCtOijWTdvzA/FpCF1xRz6S1GtVEwaLseY=";
    };
    legacyOsctldModule =
      {
        config,
        lib,
        pkgs,
        ...
      }:
      let
        daemonConfig = pkgs.writeText "legacy-osctld-config.json" (builtins.toJSON config.osctld.settings);
        legacyOsctld = pkgs.writeShellScriptBin "legacy-osctld" ''
          export RUBYLIB="${legacySource}/osctld/lib:${legacySource}/libosctl/lib"
          exec ${pkgs.osctld}/bin/osctld "$@"
        '';
      in
      {
        runit.services.osctld.run = lib.mkForce ''
          waitForService zfs-module-parameters
          waitForNetworkOnline 60
          waitForService live-patches 120

          exec 2>&1
          exec ${legacyOsctld}/bin/legacy-osctld \
            --config ${daemonConfig} \
            --log syslog \
            --log-facility local2
        '';
      };

    testService = trigger: {
      runit.services.restart-trigger-test = {
        run = ''
          ${pkgs.coreutils}/bin/mkdir -p /run/restart-trigger-test
          echo started > /run/restart-trigger-test/state
          exec ${pkgs.coreutils}/bin/sleep 3600
        '';
        restartTriggers = [ trigger ];
      };
    };

    switchedSystem =
      module:
      (import ../../../os (
        {
          importedPkgs = pkgs;
          system = pkgs.system;
          modules = [
            ../../configs/vpsadminos/base.nix
            ../../configs/vpsadminos/pool-tank.nix
            (testService triggerB)
            (nodectldTestService triggerA)
            (handoffBoundaryService triggerB)
            module
          ];
        }
        // (pkgs.vpsadminosTestFrameworkInputs or { })
      )).config.system.build.toplevel;

    nextSystem = switchedSystem {
      boot.kernelModules = [
        addedModule
        keptModule
        failedModule
      ];
    };

    unloadSystem = switchedSystem {
      boot.kernelModules = [
        keptModule
        failedModule
      ];
      boot.kernel.unloadRemovedModules = true;
    };

    loadDisabledSystem = switchedSystem {
      boot.kernelModules = [
        addedModule
        keptModule
        failedModule
      ];
      boot.kernel.loadNewModules = false;
    };

    legacyUpgradeSystem = switchedSystem {
      runit.services.osctld.restartTriggers = [ triggerB ];
      runit.services.nodectld.restartTriggers = [ triggerB ];
    };

    osctldAndNodectldRestartSystem = switchedSystem {
      runit.services.osctld.restartTriggers = [ triggerB ];
      runit.services.nodectld.restartTriggers = [ triggerB ];
    };

    osctldRetrySystem = switchedSystem {
      runit.services.osctld.restartTriggers = [ triggerC ];
      runit.services.nodectld.restartTriggers = [ triggerB ];
    };

    moduleAndFirewallSystem = switchedSystem {
      boot.kernelModules = [
        addedModule
        keptModule
        failedModule
      ];
      networking.firewall.logRefusedConnections = true;
    };

    nextFirewallSystem =
      (import ../../../os (
        {
          importedPkgs = pkgs;
          system = pkgs.system;
          modules = [
            ../../configs/vpsadminos/base.nix
            ../../configs/vpsadminos/pool-tank.nix
            (testService triggerA)
            {
              networking.firewall.logRefusedConnections = true;
            }
          ];
        }
        // (pkgs.vpsadminosTestFrameworkInputs or { })
      )).config.system.build.toplevel;
  in
  {
    name = "system-switch-to-configuration";

    description = ''
      Test switch-to-configuration service restart decisions
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config = {
        imports = [
          (testService triggerA)
          (nodectldTestService triggerA)
          (handoffBoundaryService triggerA)
          legacyOsctldModule
        ];
        boot.kernelModules = [
          removedModule
          keptModule
          failedModule
        ];
        system.extraDependencies = [
          nextSystem
          unloadSystem
          loadDisabledSystem
          moduleAndFirewallSystem
          nextFirewallSystem
          legacyUpgradeSystem
          osctldAndNodectldRestartSystem
          osctldRetrySystem
        ];
      };
    };

    testScript = ''
      require 'shellwords'

      describe 'switch-to-configuration', order: :defined do
        tracked_module_state = lambda do
          _, output = machine.succeeds(<<~CMD)
            set -e
            for module in ${removedModule} ${addedModule} ${keptModule} ${failedModule}; do
              if lsmod | awk '{print $1}' | grep -qx "$module"; then
                state=loaded
              else
                state=absent
              fi
              printf '%s=%s\\n' "$module" "$state"
            done
          CMD

          output.lines.map { |line| line.strip.split('=', 2) }.to_h
        end

        service_log_contains = lambda do |pattern|
          machine.wait_until_succeeds(
            "grep -R -q #{Shellwords.escape(pattern)} /var/log/kernel-modules"
          )
        end

        service_log_not_contains = lambda do |pattern|
          machine.succeeds(
            "! grep -R -q #{Shellwords.escape(pattern)} /var/log/kernel-modules"
          )
        end

        syslog_contains = lambda do |pattern|
          machine.wait_until_succeeds(
            "grep -F #{Shellwords.escape(pattern)} /var/log/messages | grep -Fq kernel-modules"
          )
        end

        syslog_not_contains = lambda do |pattern|
          machine.succeeds(
            "if grep -F #{Shellwords.escape(pattern)} /var/log/messages | grep -Fq kernel-modules; then exit 1; else exit 0; fi"
          )
        end

        log_contains = lambda do |pattern|
          service_log_contains.call(pattern)
          syslog_contains.call(pattern)
        end

        log_not_contains = lambda do |pattern|
          service_log_not_contains.call(pattern)
          syslog_not_contains.call(pattern)
        end

        clear_kernel_module_logs = lambda do
          machine.succeeds(<<~CMD)
            set -e
            if [ -d /var/log/kernel-modules ]; then
              find /var/log/kernel-modules -type f -exec truncate -s 0 {} +
            fi
            [ ! -e /var/log/messages ] || truncate -s 0 /var/log/messages
          CMD
        end

        before(:context) do
          machine.start
          machine.wait_for_service('rsyslog')
          machine.wait_for_service('restart-trigger-test')
          machine.wait_for_service('nodectld')
          machine.wait_until_succeeds('test -S ${nodectldSocket}')
          machine.wait_for_service('handoff-boundary-test')
          machine.wait_for_service('kernel-modules')
        end

        it 'restarts a service when only restartTriggers change' do
          machine.wait_until_succeeds('test -f /run/restart-trigger-test/state')

          _, current_run = machine.succeeds('readlink -f /etc/runit/services/restart-trigger-test/run')
          _, next_run = machine.succeeds('readlink -f ${nextSystem}/etc/runit/services/restart-trigger-test/run')

          expect(next_run.strip).to eq(current_run.strip)

          _, output = machine.succeeds('${nextSystem}/bin/switch-to-configuration dry-activate')

          expect(output).to include('> sv stop restart-trigger-test')
          expect(output).to include('> sv start restart-trigger-test')
        end

        it 'reloads the firewall when its kernel module requirements change' do
          _, output = machine.succeeds('${nextFirewallSystem}/bin/switch-to-configuration dry-activate')

          expect(output).to include('> sv 1 firewall')
          expect(output).not_to include('> sv stop firewall')
          expect(output).not_to include('> sv start firewall')
        end

        it 'keeps kernel-modules available while reloading firewall' do
          _, output = machine.succeeds('${moduleAndFirewallSystem}/bin/switch-to-configuration dry-activate')

          kernel_modules_reload = output.index('> sv reload kernel-modules')
          firewall_reload = output.index('> sv 1 firewall')

          expect(kernel_modules_reload).not_to be_nil
          expect(firewall_reload).not_to be_nil
          expect(kernel_modules_reload).to be < firewall_reload
          expect(output).not_to include('> sv stop kernel-modules')
          expect(output).not_to include('> sv start kernel-modules')
          expect(output).not_to include('> sv stop firewall')
          expect(output).not_to include('> sv start firewall')
        end

        it 'recovers an interrupted legacy handoff without losing runtime state' do
          ctid = get_container_id
          handoff_ctid = "#{ctid}-handoff"
          stopping_ctid = "#{ctid}-stopping"
          handoff_block = '/tmp/legacy-handoff-start'
          handoff_hook = "/tank/hook/ct/#{handoff_ctid}/pre-start"
          stopping_block = '/tmp/legacy-handoff-stop'
          stopping_hook = "/tank/hook/ct/#{stopping_ctid}/pre-stop"
          machine.wait_for_osctl_pool('tank')
          machine.execute("osctl ct del -f --prune #{ctid}")
          machine.execute("osctl ct del -f --prune #{handoff_ctid}")
          machine.execute("osctl ct del -f --prune #{stopping_ctid}")
          machine.all_succeed(
            "osctl ct new --distribution alpine #{ctid}",
            "osctl ct unset start-menu #{ctid}",
            "osctl ct netif new routed #{ctid} eth0",
            "osctl ct netif route add #{ctid} eth0 192.0.2.55/32",
            "osctl ct start #{ctid}",
            "osctl ct new --distribution alpine #{handoff_ctid}",
            "osctl ct unset start-menu #{handoff_ctid}",
            "osctl ct set autostart --delay 0 #{handoff_ctid}",
            "osctl ct new --distribution alpine #{stopping_ctid}",
            "osctl ct unset start-menu #{stopping_ctid}",
            "osctl ct set autostart --priority 17 --delay 0 #{stopping_ctid}",
            "osctl ct start #{stopping_ctid}"
          )
          machine.wait_for_osctl_container(ctid)
          machine.wait_for_osctl_container(stopping_ctid)
          machine.succeeds(<<~CMD)
            rm -rf #{handoff_block}
            install -d -m 755 #{handoff_block}
            install -d -m 700 #{File.dirname(handoff_hook)}
            cat > #{handoff_hook} <<'EOF'
            #!/bin/sh
            set -eu
            current_run=$(readlink -f /etc/runit/services/osctld/run)
            target_run=$(readlink -f ${legacyUpgradeSystem}/etc/runit/services/osctld/run)
            if [ "$current_run" != "$target_run" ]; then
              if [ ! -e #{handoff_block}/started ]; then
                : > #{handoff_block}/started
                while [ ! -e #{handoff_block}/release ]; do
                  sleep 0.1
                done
              fi
              exit 1
            fi
            rm -f "$0"
            EOF
            chmod 700 #{handoff_hook}
            setsid osctl ct start --queue #{handoff_ctid} \
              >#{handoff_block}/client.log 2>&1 </dev/null &
            echo $! > #{handoff_block}/client.pid

            rm -rf #{stopping_block}
            install -d -m 755 #{stopping_block}
            install -d -m 700 #{File.dirname(stopping_hook)}
            cat > #{stopping_hook} <<'EOF'
            #!/bin/sh
            set -eu
            : > #{stopping_block}/started
            while [ ! -e #{stopping_block}/release ]; do
              sleep 0.1
            done
            rm -f "$0"
            EOF
            chmod 700 #{stopping_hook}
            setsid osctl ct stop #{stopping_ctid} \
              >#{stopping_block}/client.log 2>&1 </dev/null &
            echo $! > #{stopping_block}/client.pid
          CMD
          machine.wait_until_succeeds(
            "test -e #{handoff_block}/started",
            timeout: 60
          )
          machine.wait_until_succeeds(
            "test -e #{stopping_block}/started",
            timeout: 60
          )
          before = machine.osctl_json("ct show #{ctid}")
          machine.succeeds(
            "osctl ct exec #{ctid} sh -c " \
              "'printf preserved > /tmp/runtime-upgrade-state'"
          )
          _, before_cgroup = machine.succeeds(
            "cat /proc/#{before.fetch('init_pid')}/cgroup"
          )
          _, host_veth = machine.succeeds(
            "osctl ct netif ls -H -o veth #{ctid}"
          )
          host_veth = host_veth.strip
          _, nodectld_pid = machine.succeeds(
            'cat /service/nodectld/supervise/pid'
          )
          machine.succeeds(
            'truncate -s 0 ${nodectldStateDir}/events && ' \
              'rm -f ${nodectldStateDir}/paused '
          )

          legacy_status = machine.osctl_json('daemon status')
          expect(legacy_status.fetch('legacy')).to be(true)
          machine.succeeds(<<~'CMD')
            rm -f /tmp/osctld-switch.pid /tmp/osctld-switch.log
            setsid ${legacyUpgradeSystem}/bin/switch-to-configuration test \
              >/tmp/osctld-switch.log 2>&1 </dev/null &
            echo $! > /tmp/osctld-switch.pid
          CMD
          machine.wait_until_succeeds(
            "grep -Fq '\"id\": \"#{handoff_ctid}\"' " \
              '/run/osctl/upgrade-handoff.yml',
            timeout: 60
          )
          machine.succeeds(
            "${pkgs.ruby}/bin/ruby -rjson -e \"cfg = " \
              "JSON.parse(File.read('/run/osctl/upgrade-handoff.yml')); " \
              "abort if cfg.fetch('containers').any? { |entry| " \
              "entry.fetch('id') == '#{stopping_ctid}' }\""
          )
          machine.all_succeed(
            'test -e /run/osctl/nodectld-upgrade-pause.json',
            'test -e ${nodectldStateDir}/paused',
            "test -e /etc/runit/services/nodectld/down",
            "kill -KILL \"$(ps -o ppid= -p #{Shellwords.escape(nodectld_pid.strip)} | tr -d ' ')\"",
            'sleep 1',
            "kill -0 #{Shellwords.escape(nodectld_pid.strip)}",
            'test -S ${nodectldSocket}'
          )
          machine.fails('sv check nodectld')
          machine.succeeds(
            "test \"$(cat /service/nodectld/supervise/pid)\" != " \
              "#{Shellwords.escape(nodectld_pid.strip)}"
          )
          machine.succeeds(
            "touch #{handoff_block}/release #{stopping_block}/release"
          )
          machine.wait_until_succeeds(
            "test \"$(osctl ct show -H -o state #{stopping_ctid})\" = stopped",
            timeout: 120
          )
          machine.wait_until_succeeds(
            "! grep -Fq '\"id\": \"#{stopping_ctid}\"' " \
              '/run/osctl/upgrade-handoff.yml',
            timeout: 30
          )
          machine.wait_until_succeeds(
            'test -e /run/handoff-boundary-test/stopping',
            timeout: 180
          )
          machine.all_succeed(
            'test ! -S /run/osctl/osctld.sock',
            'test -e /run/osctl/upgrade-handoff.yml',
            'test -e /run/osctl/nodectld-upgrade-pause.json',
            "${pkgs.ruby}/bin/ruby -rjson -e \"abort unless " \
              "JSON.parse(File.read('/run/osctl/nodectld-upgrade-pause.json'))" \
              "['reason'] == 'legacy-osctld-runtime-upgrade'\"",
            'test -e ${nodectldStateDir}/paused',
            'kill -KILL "$(cat /tmp/osctld-switch.pid)"',
            'touch /run/handoff-boundary-test/release'
          )
          machine.wait_until_fails(
            'kill -0 "$(cat /tmp/osctld-switch.pid)" 2>/dev/null',
            timeout: 30
          )

          _, output = machine.succeeds(
            '${legacyUpgradeSystem}/bin/switch-to-configuration test',
            timeout: 480
          )

          expect(output).to include('> recovering interrupted legacy osctld handoff')
          expect(output).not_to include('> sv stop nodectld')
          machine.wait_for_service('osctld')
          machine.wait_for_osctl_pool('tank')
          status = machine.osctl_json('daemon status')
          expect(status.fetch('legacy')).to be(false)
          expect(status.fetch('phase')).to eq('ready')

          after = machine.osctl_json("ct show #{ctid}")
          expect(after.fetch('state')).to eq('running')
          expect(after.fetch('init_pid')).to eq(before.fetch('init_pid'))
          expect(after.fetch('lifecycle_run_id')).not_to be_nil
          _, after_cgroup = machine.succeeds(
            "cat /proc/#{after.fetch('init_pid')}/cgroup"
          )
          expect(after_cgroup).to eq(before_cgroup)
          machine.wait_for_osctl_container(handoff_ctid)
          handoff_after = machine.osctl_json("ct show #{handoff_ctid}")
          expect(handoff_after.fetch('state')).to eq('running')
          expect(handoff_after.fetch('lifecycle_desired_state')).to eq('running')
          expect(handoff_after.fetch('lifecycle_residuals')).to eq(0)
          stopping_after = machine.osctl_json("ct show #{stopping_ctid}")
          expect(stopping_after.fetch('state')).to eq('stopped')
          expect(stopping_after.fetch('lifecycle_desired_state')).to eq('stopped')
          _, nodectld_events = machine.succeeds(
            'cat ${nodectldStateDir}/events'
          )
          expect(nodectld_events.lines.map(&:strip)).to include('pause', 'resume')
          _, new_nodectld_pid = machine.succeeds(
            'cat /service/nodectld/supervise/pid'
          )
          expect(new_nodectld_pid.strip).not_to eq(nodectld_pid.strip)
          machine.all_succeed(
            'test ! -e /run/osctl/upgrade-handoff.yml',
            'test ! -e /run/osctl/nodectld-upgrade-pause.json',
            'test ! -e ${nodectldStateDir}/paused',
            "test \"$(cat /service/nodectld/supervise/pid)\" = " \
              "#{Shellwords.escape(new_nodectld_pid.strip)}",
            "test -e /sys/class/net/#{host_veth}",
            "test -S /run/osctl/pools/tank/console/#{ctid}/tty0.sock",
            "ip -4 route show 192.0.2.55/32 dev #{host_veth} | " \
              'grep -Fq 192.0.2.55',
            "osctl ct exec #{ctid} true",
            "test \"$(osctl ct exec #{ctid} cat " \
              "/tmp/runtime-upgrade-state)\" = preserved",
            "osctl ct exec #{handoff_ctid} true",
            "osctl ct del -f --prune #{ctid}",
            "osctl ct del -f --prune #{handoff_ctid}",
            "osctl ct del -f --prune #{stopping_ctid}"
          )
        end

        it 'loads added modules without unloading removed modules by default' do
          expect(tracked_module_state.call).to eq(
            '${removedModule}' => 'loaded',
            '${addedModule}' => 'absent',
            '${keptModule}' => 'loaded',
            '${failedModule}' => 'absent',
          )
          log_contains.call('loading module ${removedModule}')
          log_contains.call('loading module ${keptModule}')
          log_contains.call('failed to load module ${failedModule}')
          clear_kernel_module_logs.call

          _, output = machine.succeeds('${nextSystem}/bin/switch-to-configuration test')

          expect(output).to include('> sv reload kernel-modules')
          expect(output).not_to include('> sv stop kernel-modules')
          expect(output).not_to include('> sv start kernel-modules')
          machine.wait_for_service('kernel-modules')
          log_contains.call('reloading kernel modules from service control')
          log_contains.call('loading module ${addedModule}')
          log_contains.call('not unloading removed kernel modules because boot.kernel.unloadRemovedModules is false')
          log_not_contains.call('unloading removed module ${removedModule}')
          log_not_contains.call('unloading removed module ${addedModule}')
          log_not_contains.call('unloading removed module ${keptModule}')
          expect(tracked_module_state.call).to eq(
            '${removedModule}' => 'loaded',
            '${addedModule}' => 'loaded',
            '${keptModule}' => 'loaded',
            '${failedModule}' => 'absent',
          )
        end

        it 'unloads removed modules when enabled' do
          clear_kernel_module_logs.call

          _, output = machine.succeeds('${unloadSystem}/bin/switch-to-configuration test')

          expect(output).to include('> sv reload kernel-modules')
          expect(output).not_to include('> sv stop kernel-modules')
          expect(output).not_to include('> sv start kernel-modules')
          machine.wait_for_service('kernel-modules')
          log_contains.call('reloading kernel modules from service control')
          log_contains.call('unloading removed module ${addedModule}')
          expect(tracked_module_state.call).to eq(
            '${removedModule}' => 'loaded',
            '${addedModule}' => 'absent',
            '${keptModule}' => 'loaded',
            '${failedModule}' => 'absent',
          )
        end

        it 'does not load modules when loading is disabled' do
          clear_kernel_module_logs.call

          _, output = machine.succeeds('${loadDisabledSystem}/bin/switch-to-configuration test')

          expect(output).to include('> sv reload kernel-modules')
          expect(output).not_to include('> sv stop kernel-modules')
          expect(output).not_to include('> sv start kernel-modules')
          machine.wait_for_service('kernel-modules')
          log_contains.call('reloading kernel modules from service control')
          log_contains.call('not loading new kernel modules because boot.kernel.loadNewModules is false')
          log_not_contains.call('loading module ${addedModule}')
          expect(tracked_module_state.call).to eq(
            '${removedModule}' => 'loaded',
            '${addedModule}' => 'absent',
            '${keptModule}' => 'loaded',
            '${failedModule}' => 'absent',
          )
        end

        it 'restarts changed nodectld only after osctld is ready' do
          ctid = get_container_id
          machine.wait_for_osctl_pool('tank')
          machine.execute("osctl ct del -f --prune #{ctid}")
          machine.all_succeed(
            "osctl ct new --distribution alpine #{ctid}",
            "osctl ct unset start-menu #{ctid}",
            "osctl ct netif new routed #{ctid} eth0",
            "osctl ct start #{ctid}"
          )
          machine.wait_for_osctl_container(ctid)
          before = machine.osctl_json("ct show #{ctid}")
          _, host_veth = machine.succeeds(
            "osctl ct netif ls -H -o veth #{ctid}"
          )
          host_veth = host_veth.strip
          expect(host_veth).not_to be_empty
          _, nodectld_pid = machine.succeeds(
            'cat /service/nodectld/supervise/pid'
          )
          machine.succeeds('truncate -s 0 ${nodectldStateDir}/events')

          _, output = machine.succeeds(
            '${osctldAndNodectldRestartSystem}/bin/switch-to-configuration test'
          )

          prepare = output.index('> osctl daemon prepare-stop')
          stop = output.index('> sv stop osctld')
          start = output.index('> sv start osctld')
          ready = output.index('> osctl daemon wait-ready --timeout 300')
          nodectld_stop = output.index('> sv stop nodectld')
          nodectld_start = output.index('> sv start nodectld')
          expect(
            [prepare, stop, start, ready, nodectld_stop, nodectld_start]
          ).not_to include(nil)
          expect(prepare).to be < stop
          expect(stop).to be < start
          expect(start).to be < ready
          expect(ready).to be < nodectld_stop
          expect(nodectld_stop).to be < nodectld_start

          wait_for_block(name: 'target osctld becomes ready', timeout: 120) do
            machine.osctl_json('daemon status').fetch('phase') == 'ready'
          end
          after = machine.osctl_json("ct show #{ctid}")
          expect(after.fetch('state')).to eq('running')
          expect(after.fetch('init_pid')).to eq(before.fetch('init_pid'))
          expect(after.fetch('lifecycle_run_id')).to eq(
            before.fetch('lifecycle_run_id')
          )
          _, new_nodectld_pid = machine.succeeds(
            'cat /service/nodectld/supervise/pid'
          )
          expect(new_nodectld_pid.strip).not_to eq(nodectld_pid.strip)
          _, nodectld_events = machine.succeeds(
            'cat ${nodectldStateDir}/events'
          )
          expect(nodectld_events.lines.map(&:strip)).to eq(
            ['pause', 'resume', 'stop', "start pid=#{new_nodectld_pid.strip}"]
          )
          machine.all_succeed(
            "test -e /sys/class/net/#{host_veth}",
            "osctl ct exec #{ctid} true",
            "osctl ct del -f --prune #{ctid}"
          )
        end

        it 'aborts before service changes when nodectld cannot be paused' do
          _, osctld_pid = machine.succeeds(
            'cat /service/osctld/supervise/pid'
          )
          _, nodectld_pid = machine.succeeds(
            'cat /service/nodectld/supervise/pid'
          )
          machine.succeeds(
            'truncate -s 0 ${nodectldStateDir}/events && ' \
              'touch ${nodectldStateDir}/fail-pause'
          )

          status, output = machine.execute(
            '${osctldRetrySystem}/bin/switch-to-configuration test',
            timeout: 60
          )

          expect(status).not_to eq(0), output
          expect(output).to include('> osctl daemon prepare-stop')
          expect(output).to include('> osctl daemon resume')
          expect(output).not_to include('> sv stop osctld')
          daemon_status = machine.osctl_json('daemon status')
          expect(daemon_status.fetch('phase')).to eq('ready')
          expect(daemon_status.fetch('lifecycle_admission')).to be(true)
          machine.all_succeed(
            "test \"$(cat /service/osctld/supervise/pid)\" = " \
              "#{Shellwords.escape(osctld_pid.strip)}",
            "test \"$(cat /service/nodectld/supervise/pid)\" = " \
              "#{Shellwords.escape(nodectld_pid.strip)}",
            'test ! -e ${nodectldStateDir}/paused',
            'test ! -e /run/osctl/nodectld-upgrade-pause.json',
            'rm -f ${nodectldStateDir}/fail-pause',
            'truncate -s 0 ${nodectldStateDir}/events'
          )

          _, retry_output = machine.succeeds(
            '${osctldRetrySystem}/bin/switch-to-configuration test',
            timeout: 480
          )

          expect(retry_output).to include('> sv stop osctld')
          expect(retry_output).not_to include('> sv stop nodectld')
          machine.wait_for_service('osctld')
          machine.wait_for_osctl_pool('tank')
          expect(machine.osctl_json('daemon status').fetch('phase')).to eq('ready')
          machine.succeeds(
            "test \"$(cat /service/nodectld/supervise/pid)\" = " \
              "#{Shellwords.escape(nodectld_pid.strip)}"
          )
        end

        it 'does not unload modules when kernel-modules is stopped' do
          machine.succeeds('sv stop kernel-modules')
          log_not_contains.call('unloading module ${addedModule}')
          log_not_contains.call('unloading module ${keptModule}')

          expect(tracked_module_state.call).to eq(
            '${removedModule}' => 'loaded',
            '${addedModule}' => 'absent',
            '${keptModule}' => 'loaded',
            '${failedModule}' => 'absent',
          )
        end
      end
    '';
  }
)
