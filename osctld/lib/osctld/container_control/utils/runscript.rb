module OsCtld
  module ContainerControl::Utils::Runscript
    module Frontend
      def add_network_opts(opts)
        opts.update(
          init_script: File.join('/', File.basename(init_script.path)),
          net_config: NetConfig.create(ct),
        )
      end

      def init_script
        return @init_script if @init_script

        f = Tempfile.create(['.runscript', '.sh'], ct.get_run_conf.rootfs)
        f.chmod(0500)
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
          STDIN.reopen(opts[:stdin])
          STDOUT.reopen(opts[:stdout])
          STDERR.reopen(opts[:stderr]) if opts[:stderr]

          opts[:close_fds] && opts[:close_fds].each { |fd| fd.close }

          setup_exec_run_env

          cmd = [
            'lxc-execute',
            '-P', lxc_home,
            '-n', ctid,
            '-o', log_file,
            '-s', "lxc.environment=PATH=#{system_path.join(':')}",
            '-s', "lxc.environment=HOME=/root",
            '-s', "lxc.environment=USER=root",
            '--',
            opts[:script],
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
      # @option opts [NetConfig] :net_config
      def with_configured_network(opts)
        ret = nil

        # Pipes for communicating with opts[:init_script]
        in_r, in_w = IO.pipe
        out_r, out_w = IO.pipe

        # Start the container with lxc-init
        init_pid = runscript_run(
          id: ctid,
          script: opts[:init_script],
          stdin: in_r,
          stdout: out_w,
          stderr: nil,
          close_fds: [in_w, out_r],
          wait: false,
        )

        in_r.close
        out_w.close

        # Wait for the container to be started
        if out_r.readline.strip == 'ready'
          # Configure network
          pid = lxc_ct.attach do
            setup_exec_env
            ENV['HOME'] = '/root'
            ENV['USER'] = 'root'
            opts[:net_config].setup
          end

          Process.wait2(pid)

          # Execute user command
          ret = yield
        end

        # Closing in_w will bring down opts[:init_script] and stop the container
        in_w.close
        out_r.close

        _, status = Process.wait2(init_pid)
        ret || ok(status.exitstatus)
      end
    end
  end
end
