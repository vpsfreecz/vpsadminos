require 'osctld/container_control/command'
require 'osctld/container_control/frontend'
require 'osctld/container_control/runner'
require 'osctld/container_control/utils/runscript'

module OsCtld
  # Execute command within a container
  #
  # If the container is running, the command is executed within the running
  # system. If the container is stopped, it can be started if option `:run`
  # is set. The container is started with init.lxc, not the container's own
  # init system. Static network configuration can be enabled using option
  # `:network`, otherwise there is no networking.
  class ContainerControl::Commands::Exec < ContainerControl::Command
    class Frontend < ContainerControl::Frontend
      include ContainerControl::Utils::Runscript::Frontend

      # @param opts [Hash]
      # @option opts [Array<String>] :cmd command to execute
      # @option opts [IO] :stdin
      # @option opts [IO] :stdout
      # @option opts [IO] :stderr
      # @option opts [Boolean] :run run the container if it is stopped?
      # @option opts [Boolean] :network setup network if the container is run?
      # @return [Integer] exit status
      def execute(opts)
        runner_opts = {
          cmd: opts[:cmd],
        }

        mode =
          if ct.running?
            :running
          elsif !ct.running? && opts[:run] && opts[:network]
            :run_network
          elsif !ct.running? && opts[:run]
            :run
          else
            raise ContainerControl::Error, 'container not running'
          end

        if opts[:network]
          add_network_opts(runner_opts)
        end

        ret = exec_runner(
          args: [mode, runner_opts],
          stdin: opts[:stdin],
          stdout: opts[:stdout],
          stderr: opts[:stderr],
        )
        ret.ok? ? ret.data : ret

      ensure
        cleanup_init_script
      end
    end

    class Runner < ContainerControl::Runner
      include ContainerControl::Utils::Runscript::Runner

      # @param mode [:running, :run_network, :run]
      # @param opts [Hash]
      # @option opts [Array<String>] :cmd command to execute
      # @option opts [IO] :stdin
      # @option opts [IO] :stdout
      # @option opts [IO] :stderr
      # @option opts [Boolean] :run run the container if it is stopped?
      # @option opts [Boolean] :network setup network if the container is run?
      # @option opts [String] :init_script path to the script used to control
      #                                    the container
      # @option opts [Hash] :net_config
      # @return [Integer] exit status
      def execute(mode, opts)
        send(:"exec_#{mode}", opts)
      end

      protected
      def exec_running(opts)
        pid = lxc_ct.attach(
          stdin: stdin,
          stdout: stdout,
          stderr: stderr,
        ) do
          setup_exec_env
          ENV['HOME'] = '/root'
          ENV['USER'] = 'root'
          LXC.run_command(opts[:cmd])
        end

        _, status = Process.wait2(pid)
        ok(status.exitstatus)
      end

      def exec_run(opts)
        pid = Process.fork do
          STDIN.reopen(stdin)
          STDOUT.reopen(stdout)
          STDERR.reopen(stderr)

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
            opts[:cmd],
          ].flatten

          Process.exec(*cmd)
        end

        _, status = Process.wait2(pid)
        ok(status.exitstatus)
      end

      def exec_run_network(opts)
        with_configured_network(
          init_script: opts[:init_script],
          net_config: opts[:net_config],
        ) { exec_running(opts) }
      end
    end
  end
end
