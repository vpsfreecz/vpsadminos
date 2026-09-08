require 'json'
require 'socket'
require 'io/wait'

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
      TRANSIENT_READY_TIMEOUT = 30
      TRANSIENT_EXIT_TIMEOUT = 5

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
          Process.setpgrp if opts[:process_group]
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
          process_group: true,
          wait: false
        )

        in_r.close
        out_w.close

        # Bound startup, not the user's command. Closing these pipes must
        # also happen on EOF, a malformed token or a failed network handshake.
        wait_transient_ready(out_r)
        ct_init_pid = wait_for_lxc_attachable
        ret =
          if ct_init_pid
            setup_network || yield
          else
            error('network setup failed: container is not attachable')
          end
        ret
      ensure
        [in_r, in_w, out_r, out_w].compact.each { |io| io.close unless io.closed? }
        network_socket&.close unless network_socket&.closed?
        if runner_pid
          # The init script normally exits on pipe EOF. Do not strand the
          # LXC child if startup or payload execution raised an exception.
          status = wait_for_process(runner_pid, timeout: TRANSIENT_EXIT_TIMEOUT)
          lxc_ct.stop if !status && lxc_ct.running?
          wait_for_lxc_stopped
        end
      end

      def wait_transient_ready(io)
        expected = "ready\n"
        received = ''
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TRANSIENT_READY_TIMEOUT

        while received.bytesize < expected.bytesize
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise Errno::ETIMEDOUT, 'transient init readiness timed out' if remaining <= 0

          chunk = io.read_nonblock(expected.bytesize - received.bytesize, exception: false)
          case chunk
          when :wait_readable
            io.wait_readable(remaining)
          when nil
            raise EOFError, 'transient init closed readiness pipe'
          else
            received << chunk
            raise 'invalid transient init readiness' unless expected.start_with?(received)
          end
        end
      end

      def setup_network
        raise 'transient network channel unavailable' unless network_socket

        network_socket.write("ready\n")
        ret = JSON.parse(network_socket.readline, symbolize_names: true)
        ret[:status] ? nil : error(ret[:message])
      rescue StandardError => e
        error("network setup failed: #{e.message}")
      ensure
        network_socket&.close
      end

      # Callback to osctld to relocate self-process from container's wrapper cgroup
      def osctld_wrapper_callback
        s = UNIXSocket.new("/run/osctl/user-control/#{Process.uid}.sock")

        payload = {
          cmd: :ct_wrapper_start,
          opts: {
            id: ctid,
            pool:,
            pid: Process.pid
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
