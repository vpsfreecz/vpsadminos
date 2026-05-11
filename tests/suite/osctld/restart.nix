import ../../make-test.nix (
  { pkgs }:
  {
    name = "osctld-restart";

    description = ''
      Test osctld graceful restart with idle and active clients
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/tank.nix pkgs;

    testScript = ''
      require 'shellwords'

      OSCTLD_SOCKET = '/run/osctl/osctld.sock'

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

      def self.host_job(name, script)
        dir = '/tmp/osctld-restart-jobs'
        log_path = "#{dir}/#{name}.log"
        status_path = "#{dir}/#{name}.status"
        pid_path = "#{dir}/#{name}.pid"
        runner = <<~SH
          (
            set -e
            #{script}
          )
          rc=$?
          printf '%s\\n' "$rc" > #{status_path}
          exit "$rc"
        SH

        machine.succeeds(<<~CMD)
          install -d -m 755 #{dir}
          rm -f #{log_path} #{status_path} #{pid_path}
          nohup sh -c #{Shellwords.escape(runner)} > #{log_path} 2>&1 &
          echo $! > #{pid_path}
        CMD

        {
          name:,
          log_path:,
          status_path:,
          pid_path:
        }
      end

      def self.host_job_finished?(job)
        machine.execute("test -f #{Shellwords.escape(job[:status_path])}")[0] == 0
      end

      def self.wait_host_job(job, timeout: 120)
        wait_until_block_succeeds(name: "#{job[:name]} finishes", timeout:) do
          machine.succeeds("test -f #{Shellwords.escape(job[:status_path])}")
        end

        _, status = machine.succeeds("cat #{Shellwords.escape(job[:status_path])}")
        return if status.to_i == 0

        _, log = machine.execute("cat #{Shellwords.escape(job[:log_path])} 2>/dev/null || true")
        fail "job #{job[:name]} failed with #{status.strip}: #{log}"
      end

      def self.wait_restart_draining_clients(job)
        wait_until_block_succeeds(name: 'osctld restart reaches client drain', timeout: 30) do
          machine.succeeds("test ! -S #{OSCTLD_SOCKET}")
        end

        if host_job_finished?(job)
          _, status = machine.succeeds("cat #{Shellwords.escape(job[:status_path])}")
          _, log = machine.execute("cat #{Shellwords.escape(job[:log_path])} 2>/dev/null || true")
          fail "restart finished before blocked command was released: #{status.strip}: #{log}"
        end
      end

      configure_examples do |config|
        config.default_order = :defined
      end

      ensure_ready

      describe 'idle clients' do
        it 'do not keep osctld restart hanging' do
          ready = '/tmp/osctld-restart-idle.ready'
          machine.succeeds("rm -f #{ready}")
          idle_job = host_job(
            'idle-clients',
            <<~'SH'
              ruby -rsocket -e '
                sockets = Array.new(8) do
                  s = UNIXSocket.new("/run/osctl/osctld.sock")
                  s.gets
                  s
                end

                File.write("/tmp/osctld-restart-idle.ready", "1\n")
                sockets.each(&:read)
              '
            SH
          )

          machine.wait_until_succeeds("test -e #{ready}", timeout: 60)
          restart_osctld
          wait_host_job(idle_job)
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
          start_job = host_job('ct-start', "osctl ct start #{ctid}")
          wait_block_started('ct-start')

          restart_job = host_job('restart-during-ct-start', 'sv -w 180 restart osctld')
          wait_restart_draining_clients(restart_job)

          release_block('ct-start')
          wait_host_job(start_job)
          wait_host_job(restart_job, timeout: 240)
          wait_osctld_ready
          wait_ct_running(ctid)
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

          state_job = host_job('ct-copy-state', "osctl ct cp state #{ctid}")
          wait_block_started('ct-copy-state')

          restart_job = host_job('restart-during-copy-state', 'sv -w 180 restart osctld')
          wait_restart_draining_clients(restart_job)

          release_block('ct-copy-state')
          wait_host_job(state_job, timeout: 180)
          wait_host_job(restart_job, timeout: 240)
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
