import ../../make-test.nix (
  { pkgs }:
  {
    name = "osctld-restart";

    description = ''
      Test osctld graceful restart with idle and active clients
    '';

    tags = [ "ci" ];

    machine =
      let
        baseMachine = import ../../machines/vpsadminos/tank.nix pkgs;
      in
      baseMachine
      // {
        config = baseMachine.config // {
          osctld.settings.restart = {
            drain_timeout = 5;
            cleanup_timeout = 2;
          };
        };
        shells = [
          "client"
          "restart"
        ];
      };

    testScript = ''
      require 'shellwords'

      OSCTLD_SOCKET = '/run/osctl/osctld.sock'
      JOB_DIR = '/tmp/osctld-restart-jobs'

      def self.ensure_ready
        machine.start
        wait_osctld_ready
        machine.wait_until_online
      end

      def self.wait_osctld_ready
        machine.wait_for_service('osctld')
        machine.wait_until_succeeds("test -S #{OSCTLD_SOCKET}", timeout: 60)
        machine.wait_until_succeeds(
          'osctl daemon wait-ready --timeout 180',
          timeout: 240
        )
        machine.wait_for_osctl_pool('tank')
      end

      def self.restart_osctld
        machine.succeeds('sv -w 60 restart osctld')
        wait_osctld_ready
      end

      def self.ct_state(ctid)
        machine.osctl_json("ct show #{ctid}")['state']
      end

      def self.ct_rootfs(ctid)
        machine.succeeds("osctl ct show -H -o rootfs #{ctid}")[1].strip
      end

      def self.ct_exec(ctid, command)
        machine.succeeds("osctl ct exec #{ctid} /bin/sh -c #{command.inspect}")
      end

      def self.wait_ct_running(ctid)
        wait_for_block(name: "#{ctid} becomes running", timeout: 120) do
          state = ct_state(ctid)
          next false unless state == 'running'

          state
        end

        machine.wait_until_succeeds("osctl ct exec #{ctid} true", timeout: 120)
      end

      def self.write_ct_file(ctid, path, value)
        ct_exec(
          ctid,
          "mkdir -p /#{File.dirname(path)} && printf '%s\\n' #{value.inspect} > /#{path}"
        )
      end

      def self.expect_ct_file(ctid, path, value)
        _, out = ct_exec(ctid, "cat /#{path}")
        expect(out.strip).to eq(value)
      end

      def self.cleanup_ct(*ctids)
        ctids.each do |ctid|
          machine.succeeds("osctl ct del -f --prune #{ctid} >/dev/null 2>&1 || true")
        end
      end

      def self.hook_path(ctid, hook_name)
        "/tank/hook/ct/#{ctid}/#{hook_name}"
      end

      def self.block_paths(label)
        dir = "/tmp/osctld-restart-blocks/#{label}"

        {
          dir:,
          started: "#{dir}/started",
          release: "#{dir}/release"
        }
      end

      def self.install_blocking_hook(ctid, hook_name, label)
        path = hook_path(ctid, hook_name)
        paths = block_paths(label)

        machine.succeeds(<<~CMD)
          rm -rf #{Shellwords.escape(paths[:dir])}
          install -d -m 755 #{Shellwords.escape(paths[:dir])}
          install -d -m 700 #{Shellwords.escape(File.dirname(path))}
          cat > #{Shellwords.escape(path)} <<'EOF'
          #!/bin/sh
          set -eu
          : > #{paths[:started]}
          while [ ! -e #{paths[:release]} ]; do
            sleep 0.1
          done
          EOF
          chmod 700 #{Shellwords.escape(path)}
        CMD
      end

      def self.remove_hook(ctid, hook_name)
        machine.succeeds("rm -f #{Shellwords.escape(hook_path(ctid, hook_name))}")
      end

      def self.wait_block_started(label)
        paths = block_paths(label)
        machine.wait_until_succeeds("test -e #{Shellwords.escape(paths[:started])}", timeout: 60)
      end

      def self.release_block(label)
        paths = block_paths(label)
        machine.succeeds("touch #{Shellwords.escape(paths[:release])}")
      end

      def self.release_block_if_present(label)
        paths = block_paths(label)
        machine.execute(
          "test ! -d #{Shellwords.escape(paths[:dir])} || touch #{Shellwords.escape(paths[:release])}"
        )
      end

      def self.job_ready_path(name)
        "#{JOB_DIR}/#{name}.ready"
      end

      def self.prepare_job(name)
        ready_path = job_ready_path(name)
        machine.succeeds("install -d -m 755 #{JOB_DIR} && rm -f #{Shellwords.escape(ready_path)}")
        ready_path
      end

      def self.shell_job(name, script, shell:, timeout: 120, mark_ready: true)
        ready_path = prepare_job(name)
        command = mark_ready ? ": > #{Shellwords.escape(ready_path)}\n#{script}" : script

        thread = Thread.new do
          machine.execute(command, shell:, timeout:)
        end

        job = {
          name:,
          ready_path:,
          shell:,
          thread:
        }

        wait_shell_job_ready(job) if mark_ready
        job
      end

      def self.shell_job_finished?(job)
        !job[:thread].alive?
      end

      def self.shell_job_result(job)
        job[:thread].value
      rescue StandardError => e
        fail "job #{job[:name]} raised #{e.class}: #{e.message}"
      end

      def self.wait_shell_job(job, timeout: 120)
        status, output = wait_shell_job_exit(job, timeout:)
        return if status == 0

        fail "job #{job[:name]} failed with #{status}: #{output}"
      end

      def self.wait_shell_job_exit(job, timeout: 120)
        wait_for_block(name: "#{job[:name]} exits", timeout:) do
          shell_job_finished?(job)
        end

        shell_job_result(job)
      end

      def self.wait_shell_job_ready(job, timeout: 30)
        wait_until_block_succeeds(name: "#{job[:name]} becomes ready", timeout:) do
          ready_status, = machine.execute(
            "test -f #{Shellwords.escape(job.fetch(:ready_path))}"
          )
          next true if ready_status == 0

          if shell_job_finished?(job)
            status, output = shell_job_result(job)
            fail "job #{job[:name]} exited before becoming ready with #{status}: #{output}"
          end

          false
        end
      end

      def self.event_monitor_job(name)
        ready_path = job_ready_path(name)
        shell_job(
          name,
          <<~SH,
            ruby <<'RUBY'
              require 'json'
              require 'socket'

              socket = UNIXSocket.new(#{OSCTLD_SOCKET.inspect})
              socket.gets
              socket.puts({ cmd: :event_subscribe, opts: {} }.to_json)

              response = JSON.parse(socket.gets, symbolize_names: true)

              unless response[:status] && response[:response] == 'subscribed'
                raise(response[:message] || "unexpected response: " + response.inspect)
              end

              File.write(#{ready_path.inspect}, "1\\n")

              socket.each_line do |line|
                response = JSON.parse(line, symbolize_names: true)

                unless response[:status]
                  warn "error: " + response[:message].to_s
                  exit(1)
                end

                event = response[:response]
                break if event.nil?

                puts event.to_json
                STDOUT.flush
              end
            RUBY
          SH
          shell: 'client',
          mark_ready: false
        )
      end

      def self.kill_osctld
        machine.succeeds(<<~'SH')
          pids=$(ps -eo pid=,args= | awk '$0 ~ /^[[:space:]]*[0-9]+ osctld: main$/ {print $1}')
          test -n "$pids"
          kill -KILL $pids
        SH
      end

      def self.expect_osctl_interrupted(job, expected: [])
        status, log = wait_shell_job_exit(job, timeout: 30)
        expected_messages = [
          'osctld closed connection',
          'osctld is shutting down',
          "No such file or directory - connect(2) for #{OSCTLD_SOCKET}",
          *expected
        ]

        expect(status).not_to eq(0)
        expect(log).to satisfy do |v|
          expected_messages.any? { |msg| v.include?(msg) }
        end
      end

      configure_examples do |config|
        config.default_order = :defined
      end

      ensure_ready

      describe 'idle clients' do
        it 'do not keep osctld restart hanging' do
          ready = job_ready_path('idle-clients')
          idle_job = shell_job(
            'idle-clients',
            <<~SH,
              ruby -rsocket -e '
                sockets = Array.new(8) do
                  s = UNIXSocket.new("/run/osctl/osctld.sock")
                  s.gets
                  s
                end

                File.write(#{ready.inspect}, "1\n")
                sockets.each(&:read)
              '
            SH
            shell: 'client',
            mark_ready: false
          )

          idle_job[:ready_path] = ready
          wait_shell_job_ready(idle_job, timeout: 60)
          restart_osctld
          wait_shell_job(idle_job)
        end

        it 'notifies monitor clients during graceful restart' do
          monitor_job = event_monitor_job('ct-monitor-osctld-graceful-restart')
          wait_shell_job_ready(monitor_job)

          restart_osctld

          _status, log = wait_shell_job_exit(monitor_job, timeout: 30)
          expect(log).to include('"type":"osctld_shutdown"')
        end
      end

      describe 'explicit daemon drain' do
        ctid = "#{get_container_id}-daemon-drain"

        before(:context) do
          cleanup_ct(ctid)
          machine.all_succeed(
            "osctl ct new --distribution alpine #{ctid}",
            "osctl ct unset start-menu #{ctid}"
          )
        end

        after(:context) do
          machine.execute('osctl daemon resume')
          cleanup_ct(ctid)
        end

        it 'closes admission until the prepared daemon is resumed' do
          machine.succeeds('osctl daemon prepare-stop')
          status = machine.osctl_json('daemon status')
          expect(status.fetch('phase')).to eq('prepared')
          expect(status.fetch('lifecycle_admission')).to be(false)

          _, rejected = machine.fails("osctl ct start #{ctid}")
          expect(rejected).to include('container lifecycle admission is closed')

          machine.succeeds('osctl daemon resume')
          expect(machine.osctl_json('daemon status').fetch('phase')).to eq('ready')
          machine.succeeds("osctl ct start #{ctid}")
          wait_ct_running(ctid)
        end
      end

      describe 'clients after abrupt osctld death' do
        it 'ct monitor exits instead of spinning' do
          monitor_job = shell_job(
            'ct-monitor-osctld-killed',
            'osctl ct monitor',
            shell: 'client'
          )

          kill_osctld
          expect_osctl_interrupted(monitor_job)
          wait_osctld_ready
        end

        it 'ct top exits instead of spinning' do
          top_job = shell_job(
            'ct-top-osctld-killed',
            'osctl -j ct top --rate 60',
            shell: 'client'
          )

          kill_osctld
          expect_osctl_interrupted(top_job)
          wait_osctld_ready
        end
      end

      describe 'active container start' do
        ctid = "#{get_container_id}-start-restart"

        before(:context) do
          wait_osctld_ready
          cleanup_ct(ctid)
          machine.all_succeed(
            "osctl ct new --distribution alpine #{ctid}",
            "osctl ct unset start-menu #{ctid}"
          )
        end

        after(:context) do
          release_block_if_present('ct-start')
          remove_hook(ctid, 'pre-start')
          cleanup_ct(ctid)
        end

        it 'drains before restart even after the sv client times out' do
          install_blocking_hook(ctid, 'pre-start', 'ct-start')
          start_job = shell_job('ct-start', "osctl ct start #{ctid}", shell: 'client')
          wait_block_started('ct-start')
          blocked_run_id = machine.osctl_json("ct show #{ctid}")['lifecycle_run_id']
          _, old_daemon_pid = machine.succeeds(
            'cat /service/osctld/supervise/pid'
          )
          old_daemon_pid = old_daemon_pid.strip

          restart_status, restart_output = machine.execute(
            'sv -w 1 restart osctld',
            shell: 'restart',
            timeout: 30
          )
          expect(restart_status).not_to eq(0), restart_output
          status = machine.osctl_json('daemon status')
          expect(status.fetch('phase')).to eq('draining')
          expect(status.fetch('lifecycle_admission')).to be(false)
          expect(shell_job_finished?(start_job)).to be(false)

          release_block('ct-start')
          wait_shell_job(start_job, timeout: 120)
          machine.wait_until_succeeds(
            "test \"$(cat /service/osctld/supervise/pid)\" != " \
              "#{Shellwords.escape(old_daemon_pid)}",
            timeout: 120
          )
          wait_osctld_ready
          wait_ct_running(ctid)

          info = machine.osctl_json("ct show #{ctid}")
          expect(info.fetch('lifecycle_run_id')).to eq(blocked_run_id)
          expect(info.fetch('lifecycle_state')).to eq('running')
        end
      end

      describe 'interrupted autostart' do
        ctid = "#{get_container_id}-auto-kill"

        before(:context) do
          wait_osctld_ready
          cleanup_ct(ctid)
          machine.all_succeed(
            "osctl ct new --distribution alpine #{ctid}",
            "osctl ct unset start-menu #{ctid}",
            "osctl ct set autostart --delay 0 #{ctid}"
          )
        end

        after(:context) do
          release_block_if_present('ct-autostart-killed')
          remove_hook(ctid, 'pre-start')
          cleanup_ct(ctid)
        end

        it 'converges to one active generation after daemon SIGKILL' do
          install_blocking_hook(ctid, 'pre-start', 'ct-autostart-killed')
          machine.succeeds('osctl pool autostart trigger tank')
          wait_block_started('ct-autostart-killed')
          before = machine.osctl_json("ct show #{ctid}")
          expect(before.fetch('lifecycle_desired_state')).to eq('running')
          expect(before.fetch('lifecycle_run_id')).not_to be_nil

          kill_osctld
          release_block('ct-autostart-killed')
          wait_osctld_ready
          machine.succeeds(
            'osctl daemon wait-ready --timeout 180',
            timeout: 240
          )
          wait_ct_running(ctid)

          after = machine.osctl_json("ct show #{ctid}")
          expect(after.fetch('state')).to eq('running')
          expect(after.fetch('lifecycle_desired_state')).to eq('running')
          expect(after.fetch('lifecycle_state')).to eq('running')
          expect(after.fetch('lifecycle_run_id')).not_to be_nil
          expect(after.fetch('lifecycle_residuals')).to eq(0)
        end
      end

      describe 'in-container reboot with a concurrent external start' do
        ctid = "#{get_container_id}-reboot-start"

        before(:context) do
          wait_osctld_ready
          cleanup_ct(ctid)
          machine.all_succeed(
            "osctl ct new --distribution alpine #{ctid}",
            "osctl ct unset start-menu #{ctid}",
            "osctl ct netif new routed #{ctid} eth0",
            "osctl ct start #{ctid}"
          )
          wait_ct_running(ctid)
        end

        after(:context) do
          release_block_if_present('ct-reboot-start')
          remove_hook(ctid, 'post-stop')
          cleanup_ct(ctid)
        end

        it 'converges on one replacement generation' do
          old_run_id = machine.osctl_json("ct show #{ctid}")['lifecycle_run_id']
          install_blocking_hook(ctid, 'post-stop', 'ct-reboot-start')

          reboot_job = shell_job(
            'ct-reboot-start-trigger',
            "osctl ct exec #{ctid} /sbin/reboot -f >/dev/null 2>&1 || true",
            shell: 'client'
          )
          wait_block_started('ct-reboot-start')

          start_job = shell_job(
            'ct-reboot-start-external',
            "osctl ct start --wait infinity #{ctid}",
            shell: 'restart',
            timeout: 240
          )

          expect(shell_job_finished?(start_job)).to be(false)
          release_block('ct-reboot-start')

          wait_shell_job(reboot_job)
          wait_shell_job(start_job, timeout: 240)
          wait_ct_running(ctid)

          info = machine.osctl_json("ct show #{ctid}")
          expect(info['lifecycle_run_id']).not_to eq(old_run_id)
          expect(info['lifecycle_state']).to eq('running')
          expect(info['lifecycle_residuals']).to eq(0)
        end
      end

      describe 'active container restart after abrupt osctld death' do
        ctid = "#{get_container_id}-restart-killed"

        before(:context) do
          wait_osctld_ready
          cleanup_ct(ctid)
          machine.all_succeed(
            "osctl ct new --distribution alpine #{ctid}",
            "osctl ct unset start-menu #{ctid}",
            "osctl ct netif new routed #{ctid} eth0",
            "osctl ct start #{ctid}"
          )
          wait_ct_running(ctid)
        end

        after(:context) do
          release_block_if_present('ct-restart-killed')
          remove_hook(ctid, 'pre-stop')
          cleanup_ct(ctid)
        end

        it 'ct restart exits instead of spinning' do
          install_blocking_hook(ctid, 'pre-stop', 'ct-restart-killed')
          restart_job = shell_job(
            'ct-restart-osctld-killed',
            "osctl ct restart #{ctid}",
            shell: 'client'
          )
          wait_block_started('ct-restart-killed')

          kill_osctld
          expect_osctl_interrupted(restart_job)
          release_block('ct-restart-killed')
          wait_osctld_ready
        end
      end

      describe 'running container with a missing host veth' do
        ctid = "#{get_container_id}-missing-veth"

        before(:context) do
          wait_osctld_ready
          cleanup_ct(ctid)
          machine.all_succeed(
            "osctl ct new --distribution alpine #{ctid}",
            "osctl ct unset start-menu #{ctid}",
            "osctl ct netif new routed #{ctid} eth0",
            "osctl ct start #{ctid}"
          )
          wait_ct_running(ctid)
        end

        after(:context) do
          cleanup_ct(ctid)
        end

        it 'performs one controlled generation restart and restores networking' do
          write_ct_file(ctid, 'tmp/osctld-restart-veth/state', 'preserved')
          before = machine.osctl_json("ct show #{ctid}")
          _, host_veth = machine.succeeds(
            "osctl ct netif ls -H -o veth #{ctid}"
          )
          host_veth = host_veth.strip
          expect(host_veth).not_to be_empty

          machine.succeeds("ip link del #{Shellwords.escape(host_veth)}")
          restart_osctld
          wait_ct_running(ctid)

          after = machine.osctl_json("ct show #{ctid}")
          expect(after.fetch('init_pid')).not_to eq(before.fetch('init_pid'))
          expect(after.fetch('lifecycle_run_id')).not_to eq(
            before.fetch('lifecycle_run_id')
          )
          _, recovered_veth = machine.succeeds(
            "osctl ct netif ls -H -o veth #{ctid}"
          )
          recovered_veth = recovered_veth.strip
          expect(recovered_veth).not_to be_empty
          machine.succeeds(
            "test -e /sys/class/net/#{Shellwords.escape(recovered_veth)}"
          )
          machine.succeeds("osctl ct exec #{ctid} true")
          expect_ct_file(ctid, 'tmp/osctld-restart-veth/state', 'preserved')
        end
      end

      describe 'parallel missing console sockets' do
        first_ctid = "#{get_container_id}-console-a"
        second_ctid = "#{get_container_id}-console-b"

        before(:context) do
          wait_osctld_ready
          cleanup_ct(first_ctid, second_ctid)
          machine.all_succeed(
            "osctl ct new --distribution alpine #{first_ctid}",
            "osctl ct unset start-menu #{first_ctid}",
            "osctl ct start #{first_ctid}",
            "osctl ct new --distribution alpine #{second_ctid}",
            "osctl ct unset start-menu #{second_ctid}",
            "osctl ct start #{second_ctid}"
          )
          wait_ct_running(first_ctid)
          wait_ct_running(second_ctid)
        end

        after(:context) do
          cleanup_ct(first_ctid, second_ctid)
        end

        it 'degrades each console independently without blocking readiness' do
          before = [first_ctid, second_ctid].to_h do |ctid|
            [ctid, machine.osctl_json("ct show #{ctid}")]
          end
          socket_paths = [first_ctid, second_ctid].to_h do |ctid|
            [ctid, "/run/osctl/pools/tank/console/#{ctid}/tty0.sock"]
          end

          machine.all_succeed(
            *socket_paths.values.map do |path|
              "test -S #{Shellwords.escape(path)} && " \
                "rm -f #{Shellwords.escape(path)}"
            end
          )
          restart_osctld

          expect(machine.osctl_json('daemon status').fetch('phase')).to eq('ready')
          [first_ctid, second_ctid].each do |ctid|
            after = machine.osctl_json("ct show #{ctid}")
            expect(after.fetch('state')).to eq('running')
            expect(after.fetch('init_pid')).to eq(before.fetch(ctid).fetch('init_pid'))
            expect(after.fetch('lifecycle_run_id')).to eq(
              before.fetch(ctid).fetch('lifecycle_run_id')
            )
            machine.all_succeed(
              "test ! -e #{Shellwords.escape(socket_paths.fetch(ctid))}",
              "osctl ct exec #{ctid} true"
            )
          end
        end
      end

      describe 'repairable host network drift' do
        routed_ctid = "#{get_container_id}-routed-drift"
        bridge_ctid = "#{get_container_id}-bridge-drift"

        before(:context) do
          wait_osctld_ready
          cleanup_ct(routed_ctid, bridge_ctid)
          machine.all_succeed(
            "osctl ct new --distribution alpine #{routed_ctid}",
            "osctl ct unset start-menu #{routed_ctid}",
            "osctl ct netif new routed --max-tx 10M --max-rx 20M " \
              "#{routed_ctid} eth0",
            "osctl ct netif route add #{routed_ctid} eth0 192.0.2.100/32",
            "osctl ct start #{routed_ctid}",
            "osctl ct new --distribution alpine #{bridge_ctid}",
            "osctl ct unset start-menu #{bridge_ctid}",
            "osctl ct netif new bridge --link lxcbr0 #{bridge_ctid} eth0",
            "osctl ct start #{bridge_ctid}"
          )
          wait_ct_running(routed_ctid)
          wait_ct_running(bridge_ctid)
        end

        after(:context) do
          cleanup_ct(routed_ctid, bridge_ctid)
        end

        it 'restores owned state without removing foreign routes' do
          routed_before = machine.osctl_json("ct show #{routed_ctid}")
          bridge_before = machine.osctl_json("ct show #{bridge_ctid}")
          _, routed_veth = machine.succeeds(
            "osctl ct netif ls -H -o veth #{routed_ctid}"
          )
          _, bridge_veth = machine.succeeds(
            "osctl ct netif ls -H -o veth #{bridge_ctid}"
          )
          routed_veth = routed_veth.strip
          bridge_veth = bridge_veth.strip

          machine.all_succeed(
            "ip -4 route del 192.0.2.100/32 dev #{routed_veth}",
            "ip -4 route add 192.0.2.101/32 dev #{routed_veth}",
            "tc qdisc del root dev #{routed_veth}",
            "tc qdisc del dev #{routed_veth} ingress",
            "ip link del ifb#{routed_veth}",
            "ip link set #{bridge_veth} nomaster"
          )
          restart_osctld

          machine.all_succeed(
            "ip -4 route show 192.0.2.100/32 dev #{routed_veth} | " \
              'grep -Fq 192.0.2.100',
            "ip -4 route show 192.0.2.101/32 dev #{routed_veth} | " \
              'grep -Fq 192.0.2.101',
            "tc qdisc show dev #{routed_veth} | grep -Fq cake",
            "tc qdisc show dev #{routed_veth} | grep -Fq ingress",
            "tc filter show dev #{routed_veth} ingress | grep -Fq mirred",
            "tc qdisc show dev ifb#{routed_veth} | grep -Fq cake",
            "test \"$(basename \"$(readlink -f " \
              "/sys/class/net/#{bridge_veth}/master)\")\" = lxcbr0"
          )
          routed_after = machine.osctl_json("ct show #{routed_ctid}")
          bridge_after = machine.osctl_json("ct show #{bridge_ctid}")
          expect(routed_after.fetch('init_pid')).to eq(
            routed_before.fetch('init_pid')
          )
          expect(bridge_after.fetch('init_pid')).to eq(
            bridge_before.fetch('init_pid')
          )
        end
      end

      describe 'missing host veth while stopping' do
        ctid = "#{get_container_id}-stop-veth"

        before(:context) do
          wait_osctld_ready
          cleanup_ct(ctid)
          machine.all_succeed(
            "osctl ct new --distribution alpine #{ctid}",
            "osctl ct unset start-menu #{ctid}",
            "osctl ct netif new routed #{ctid} eth0",
            "osctl ct start #{ctid}"
          )
          wait_ct_running(ctid)
        end

        after(:context) do
          release_block_if_present('ct-stop-missing-veth')
          remove_hook(ctid, 'pre-stop')
          cleanup_ct(ctid)
        end

        it 'finishes the desired stop without scheduling a recovery restart' do
          install_blocking_hook(ctid, 'pre-stop', 'ct-stop-missing-veth')
          stop_job = shell_job(
            'ct-stop-missing-veth',
            "osctl ct stop #{ctid}",
            shell: 'client'
          )
          wait_block_started('ct-stop-missing-veth')
          expect(
            machine.osctl_json("ct show #{ctid}").fetch(
              'lifecycle_desired_state'
            )
          ).to eq('stopped')
          _, host_veth = machine.succeeds(
            "osctl ct netif ls -H -o veth #{ctid}"
          )
          machine.succeeds("ip link del #{Shellwords.escape(host_veth.strip)}")

          kill_osctld
          expect_osctl_interrupted(stop_job)
          release_block('ct-stop-missing-veth')
          wait_osctld_ready
          machine.succeeds(
            'osctl daemon wait-ready --timeout 180',
            timeout: 240
          )
          machine.wait_until_succeeds(
            "test \"$(osctl ct show -H -o state #{ctid})\" = stopped",
            timeout: 120
          )

          after = machine.osctl_json("ct show #{ctid}")
          expect(after.fetch('lifecycle_desired_state')).to eq('stopped')
          expect(after.fetch('state')).to eq('stopped')
          expect(after.fetch('lifecycle_residuals')).to eq(0)
        end
      end

      describe 'stopped container with live cgroup processes' do
        ctid = "#{get_container_id}-stopped-live"
        pid_path = '/tmp/osctld-stopped-live-cgroup.pid'
        cgroup_path = '/tmp/osctld-stopped-live-cgroup.path'

        before(:context) do
          wait_osctld_ready
          cleanup_ct(ctid)
          machine.succeeds("osctl ct new --distribution alpine #{ctid}")
        end

        after(:context) do
          machine.execute(<<~CMD)
            test ! -e #{pid_path} || kill "$(cat #{pid_path})" 2>/dev/null || true
            test ! -e #{cgroup_path} || rmdir "$(cat #{cgroup_path})" 2>/dev/null || true
            rm -f #{pid_path} #{cgroup_path}
          CMD
          cleanup_ct(ctid)
        end

        it 'fails drain without signalling the unowned process' do
          machine.succeeds(<<~CMD)
            set -eu
            group_path=$(osctl ct show -H -o group_path #{ctid})
            group_path="''${group_path#/}"
            base="/sys/fs/cgroup/''${group_path%/user-owned}"
            echo "$base/restart-test-orphan" > #{cgroup_path}
            orphan=$(cat #{cgroup_path})
            mkdir -p "$orphan"
            sleep 300 >/dev/null 2>&1 &
            pid=$!
            echo "$pid" > "$orphan/cgroup.procs"
            echo "$pid" > #{pid_path}
          CMD

          status, output = machine.execute(
            'osctl daemon prepare-stop',
            timeout: 30
          )
          expect(status).not_to eq(0), output
          expect(machine.osctl_json('daemon status').fetch('phase')).to eq(
            'drain_failed'
          )
          machine.succeeds("kill -0 \"$(cat #{pid_path})\"")

          machine.succeeds(<<~CMD)
            kill "$(cat #{pid_path})"
            sleep 0.2
            rmdir "$(cat #{cgroup_path})"
            rm -f #{pid_path} #{cgroup_path}
            osctl daemon resume
            osctl daemon wait-ready --timeout 30
          CMD
        end

        it 'blocks readiness until the unowned process is removed' do
          machine.succeeds(<<~CMD)
            set -eu
            group_path=$(osctl ct show -H -o group_path #{ctid})
            group_path="''${group_path#/}"
            base="/sys/fs/cgroup/''${group_path%/user-owned}"
            echo "$base/restart-test-orphan" > #{cgroup_path}
            osctl daemon prepare-stop
            sv -w 60 stop osctld
            orphan=$(cat #{cgroup_path})
            mkdir -p "$orphan"
            sleep 300 >/dev/null 2>&1 &
            pid=$!
            echo "$pid" > "$orphan/cgroup.procs"
            echo "$pid" > #{pid_path}
            sv start osctld
          CMD

          machine.wait_until_succeeds("test -S #{OSCTLD_SOCKET}", timeout: 60)
          machine.wait_until_succeeds(
            "osctl --json daemon status | " \
              "grep -Fq 'configured_container_unowned_processes'",
            timeout: 60
          )
          status = machine.osctl_json('daemon status')
          expect(status.fetch('phase')).to eq('blocked')

          machine.succeeds(<<~CMD)
            kill "$(cat #{pid_path})"
            sleep 0.2
            rmdir "$(cat #{cgroup_path})"
            rm -f #{pid_path} #{cgroup_path}
          CMD
          kill_osctld
          wait_osctld_ready
          machine.succeeds(
            'osctl daemon wait-ready --timeout 180',
            timeout: 240
          )
        end
      end

      describe 'active local copy state' do
        ctid = "#{get_container_id}-copy"
        target = "#{ctid}-dst"

        before(:context) do
          wait_osctld_ready
          cleanup_ct(ctid, target)
          machine.all_succeed(
            "osctl ct new --distribution alpine #{ctid}",
            "osctl ct unset start-menu #{ctid}",
            "osctl ct start #{ctid}"
          )
          wait_ct_running(ctid)
          machine.all_succeed(
            "osctl ct cp config #{ctid} #{target}",
            "osctl ct cp rootfs #{ctid}"
          )
        end

        after(:context) do
          release_block_if_present('ct-copy-state')
          remove_hook(ctid, 'pre-stop')
          cleanup_ct(ctid, target)
        end

        it 'continues through restart and remains cleanup-capable' do
          write_ct_file(ctid, 'tmp/osctld-restart-copy/state', 'state-after-restart')
          install_blocking_hook(ctid, 'pre-stop', 'ct-copy-state')

          state_job = shell_job(
            'ct-copy-state',
            "osctl ct cp state #{ctid}",
            shell: 'client',
            timeout: 180
          )
          wait_block_started('ct-copy-state')

          restart_job = shell_job(
            'restart-during-copy-state',
            'sv -w 180 restart osctld',
            shell: 'restart',
            timeout: 240
          )
          machine.wait_until_succeeds("test ! -S #{OSCTLD_SOCKET}", timeout: 30)
          expect_osctl_interrupted(
            state_job,
            expected: [
              "hook pre_stop at #{hook_path(ctid, 'pre-stop')} exited"
            ]
          )
          release_block('ct-copy-state')
          wait_shell_job(restart_job, timeout: 240)
          wait_osctld_ready

          machine.wait_until_succeeds(
            "test \"$(osctl ct show -H -o state #{ctid})\" = stopped",
            timeout: 120
          )

          machine.succeeds("osctl ct cp state #{ctid}")
          machine.succeeds("osctl ct cp cleanup #{ctid}")
          machine.succeeds("osctl ct start #{target}")
          wait_ct_running(target)
          expect_ct_file(target, 'tmp/osctld-restart-copy/state', 'state-after-restart')
        end
      end
    '';
  }
)
