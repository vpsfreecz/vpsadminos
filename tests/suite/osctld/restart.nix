import ../../make-test.nix (
  { pkgs }:
  {
    name = "osctld-restart";

    description = ''
      Test osctld graceful restart with idle and active clients
    '';

    tags = [ "ci" ];

    machine = (import ../../machines/vpsadminos/tank.nix pkgs) // {
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
          if shell_job_finished?(job)
            status, output = shell_job_result(job)
            fail "job #{job[:name]} exited before becoming ready with #{status}: #{output}"
          end

          machine.succeeds("test -f #{Shellwords.escape(job.fetch(:ready_path))}")
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

      def self.expect_osctl_lost_osctld(job)
        status, log = wait_shell_job_exit(job, timeout: 30)
        expected = [
          'osctld closed connection',
          "No such file or directory - connect(2) for #{OSCTLD_SOCKET}"
        ]

        expect(status).not_to eq(0)
        expect(log).to satisfy { |v| expected.any? { |msg| v.include?(msg) } }
      end

      def self.wait_restart_draining_clients(job)
        wait_until_block_succeeds(name: 'osctld restart reaches client drain', timeout: 30) do
          machine.succeeds("test ! -S #{OSCTLD_SOCKET}")
        end

        if shell_job_finished?(job)
          status, output = shell_job_result(job)
          fail "restart finished before blocked command was released: #{status}: #{output}"
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

      describe 'clients after abrupt osctld death' do
        it 'ct monitor exits instead of spinning' do
          monitor_job = shell_job(
            'ct-monitor-osctld-killed',
            'osctl ct monitor',
            shell: 'client'
          )

          kill_osctld
          expect_osctl_lost_osctld(monitor_job)
          wait_osctld_ready
        end

        it 'ct top exits instead of spinning' do
          top_job = shell_job(
            'ct-top-osctld-killed',
            'osctl -j ct top --rate 60',
            shell: 'client'
          )

          kill_osctld
          expect_osctl_lost_osctld(top_job)
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

        it 'continues through a concurrent osctld restart' do
          install_blocking_hook(ctid, 'pre-start', 'ct-start')
          start_job = shell_job('ct-start', "osctl ct start #{ctid}", shell: 'client')
          wait_block_started('ct-start')

          restart_job = shell_job(
            'restart-during-ct-start',
            'sv -w 180 restart osctld',
            shell: 'restart',
            timeout: 240
          )
          wait_restart_draining_clients(restart_job)

          release_block('ct-start')
          wait_shell_job(start_job)
          wait_shell_job(restart_job, timeout: 240)
          wait_osctld_ready
          wait_ct_running(ctid)
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
          expect_osctl_lost_osctld(restart_job)
          release_block('ct-restart-killed')
          wait_osctld_ready
        end
      end

      describe 'active local copy state' do
        ctid = "#{get_container_id}-copy-restart"
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
          wait_restart_draining_clients(restart_job)

          release_block('ct-copy-state')
          wait_shell_job(state_job, timeout: 180)
          wait_shell_job(restart_job, timeout: 240)
          wait_osctld_ready

          machine.succeeds("osctl ct cp cleanup #{ctid}")
          machine.succeeds("osctl ct start #{target}")
          wait_ct_running(target)
          expect_ct_file(target, 'tmp/osctld-restart-copy/state', 'state-after-restart')
        end
      end
    '';
  }
)
