require 'json'
require 'socket'

module OsCtld
  module ContainerControl::Utils::Runscript
    module Frontend
      def runscript_mode(run:, network:)
        running = run ? ct.current_state == :running : ct.running?

        if running
          :running
        elsif run && network
          :run_network
        elsif run
          :run
        else
          raise ContainerControl::Error, 'container not running'
        end
      end

      def sync_state_after_transient_run(mode)
        ct.current_state if %i[run run_network].include?(mode)
      end

      def issue_transient_lifecycle_start(mode)
        return unless %i[run run_network].include?(mode)

        ct.run_conf.issue_lifecycle_start
      end

      def add_network_opts(opts)
        opts.update(
          init_script: File.join('/', File.basename(init_script.path))
        )
      end

      def init_script
        return @init_script if @init_script

        f = Tempfile.create(['.runscript', '.sh'], ct.get_run_conf.rootfs)
        f.chmod(0o500)
        f.puts('#!/bin/sh')
        f.puts('echo ready')
        f.puts('read _')
        f.close

        @init_script = f
      end

      def cleanup_init_script
        @init_script && unlink_file(@init_script.path)
      end

      def unlink_file(path)
        File.unlink(path)
      rescue SystemCallError
        # pass
      end
    end

    module Runner
      # Execute script in a stopped container
      # @param opts [Hash]
      # @option opts [String] :script path to the script relative to the rootfs
      # @option opts [IO] :stdin
      # @option opts [IO] :stdout
      # @option opts [IO] :stderr
      # @option opts [Array<IO>] :close_fds
      # @option opts [Boolean] :wait
      def runscript_run(opts)
        pid = Process.fork do
          cur_stdin = opts.fetch(:stdin, stdin)
          cur_stdout = opts.fetch(:stdout, stdout)
          cur_stderr = opts.fetch(:stderr, stderr)

          if cur_stdin
            $stdin.reopen(cur_stdin)
          else
            $stdin.close
          end

          $stdout.reopen(cur_stdout)
          $stderr.reopen(cur_stderr) if cur_stderr

          opts[:close_fds] && opts[:close_fds].each(&:close)

          setup_exec_run_env
          osctld_wrapper_callback

          cmd = [
            'lxc-execute',
            '-P', lxc_home,
            '-n', ctid,
            '-o', log_file,
            '-s', "lxc.environment=PATH=#{system_path.join(':')}",
            '-s', 'lxc.environment=HOME=/root',
            '-s', 'lxc.environment=USER=root',
            '--',
            opts[:script]
          ]

          # opts[:cmd] can contain an arbitrary command with multiple arguments
          # and quotes, so the mapping to process arguments is not clear. We use
          # the shell to handle this.
          Process.exec("exec #{cmd.join(' ')}")
        end

        if opts[:wait] === false
          pid
        else
          _, status = Process.wait2(pid)
          wait_for_lxc_stopped
          ok(status.exitstatus)
        end
      end

      # Start container with lxc-init, configure network and yield
      #
      # opts[:init_script] has to contain path to a script that will be executed
      # by lxc-init. The purpose of this script is to keep the container running
      # while the network is being configured and the user command is executed.
      # The script has to write `ready\n` to standard output, then block on read
      # from standard input and exit.
      #
      # @param opts [Hash]
      # @option opts [String] :init_script path to the script used to control
      #                                    the container
      # @option opts [Hash] :net_config
      def with_configured_network(opts)
        ret = nil

        # Pipes for communicating with opts[:init_script]
        in_r, in_w = IO.pipe
        out_r, out_w = IO.pipe

        # Start the container with lxc-init
        runner_pid = runscript_run(
          id: ctid,
          script: opts[:init_script],
          stdin: in_r,
          stdout: out_w,
          stderr: nil,
          close_fds: [in_w, out_r],
          wait: false
        )

        in_r.close
        out_w.close

        # Wait for the container to be started
        if out_r.readline.strip == 'ready'
          ct_init_pid = wait_for_lxc_attachable

          ret =
            if ct_init_pid
              setup_network || yield
            else
              error('network setup failed: container is not attachable')
            end
        end

        # Closing in_w will bring down opts[:init_script] and stop the container
        in_w.close
        out_r.close

        _, status = Process.wait2(runner_pid)
        wait_for_lxc_stopped
        ret || ok(status.exitstatus)
      end

      def setup_network
        osctld_netns_setup
        nil
      rescue StandardError => e
        error("network setup failed: #{e.message}")
      end

      def osctld_netns_setup
        s = UNIXSocket.new("/run/osctl/user-control/#{Process.uid}.sock")

        payload = {
          cmd: :ct_netns_setup,
          opts: {
            id: ctid,
            pool:,
            run_id:
          }
        }

        s.send("#{payload.to_json}\n", 0)

        ret = JSON.parse(s.readline, symbolize_names: true)
        s.close

        return if ret[:status]

        raise "Error during ct_netns_setup callback: #{ret[:message]}"
      end

      # Register the transient LXC lifecycle from its already-assigned cgroup.
      def osctld_wrapper_callback
        unless lifecycle_start_token.is_a?(String) && !lifecycle_start_token.empty?
          raise 'missing transient lifecycle start capability'
        end

        s = UNIXSocket.new("/run/osctl/user-control/#{Process.uid}.sock")

        payload = {
          cmd: :ct_wrapper_start,
          opts: {
            id: ctid,
            pool:,
            run_id:,
            lifecycle_start_token:
          }
        }

        s.send("#{payload.to_json}\n", 0)

        ret = JSON.parse(s.readline, symbolize_names: true)
        s.close

        return if ret[:status]

        raise "Error during ct_wrapper_start callback: #{ret[:message]}"
      end
    end
  end
end
