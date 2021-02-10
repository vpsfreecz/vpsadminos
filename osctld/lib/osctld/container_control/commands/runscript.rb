require 'osctld/container_control/command'
require 'osctld/container_control/frontend'
require 'osctld/container_control/runner'
require 'osctld/container_control/utils/runscript'

module OsCtld
  # Execute a script within a container
  #
  # If the container is running, the script is executed within the running
  # system. If the container is stopped, it can be started if option `:run`
  # is set. The container is started with init.lxc, not the container's own
  # init system. Static network configuration can be enabled using option
  # `:network`, otherwise there is no networking.
  class ContainerControl::Commands::Runscript < ContainerControl::Command
    class Frontend < ContainerControl::Frontend
      include ContainerControl::Utils::Runscript::Frontend

      # @param opts [Hash]
      # @option opts [String] :script path to the script on the host
      # @option opts [Array<String>] :args script arguments
      # @option opts [IO] :stdin
      # @option opts [IO] :stdout
      # @option opts [IO] :stderr
      # @option opts [Boolean] :run run the container if it is stopped?
      # @option opts [Boolean] :network setup network if the container is run?
      # @return [Integer] exit status
      def execute(opts)
        opts = opts.clone

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

        add_network_opts(opts) if opts[:network]

        script = copy_script(opts[:script])
        opts[:script] = File.join('/', File.basename(script.path))

        ret = pipe_runner(
          args: [mode, opts],
          keep_fds: [
            opts[:stdin],
            opts[:stdout],
            opts[:stderr],
          ],
        )
        ret.ok? ? ret.data : ret

      ensure
        script.close
        unlink_file(script.path)
        cleanup_init_script
      end

      protected
      def copy_script(src)
        script = Tempfile.create(['.runscript', '.sh'], ct.get_run_conf.rootfs)
        script.chmod(0500)

        File.open(src, 'r') { |f| IO.copy_stream(f, script) }
        script.close
        script
      end
    end

    class Runner < ContainerControl::Runner
      include ContainerControl::Utils::Runscript::Runner

      # @param mode [:running, :run_network, :run]
      # @param opts [Hash]
      # @option opts [String] :script path to the script relative to the rootfs
      # @option opts [Array<String>] :args script arguments
      # @option opts [IO] :stdin
      # @option opts [IO] :stdout
      # @option opts [IO] :stderr
      # @option opts [Boolean] :run run the container if it is stopped?
      # @option opts [Boolean] :network setup network if the container is run?
      # @option opts [String] :init_script path to the script used to control
      #                                    the container
      # @option opts [NetConfig] :net_config
      # @option opts [Array<IO>] :close_fds
      # @option opts [Boolean] :wait
      # @return [Integer] exit status
      def execute(mode, opts)
        send(:"runscript_#{mode}", opts)
      end

      protected
      def runscript_running(opts)
        pid = lxc_ct.attach(
          stdin: opts[:stdin],
          stdout: opts[:stdout],
          stderr: opts[:stderr]
        ) do
          setup_exec_env
          ENV['HOME'] = '/root'
          ENV['USER'] = 'root'

          # FIXME: *something* must be keeping opts[:script] open, because when
          # runscript is run in parallel, 1-2 out of 10 calls fail with ETXTBSY,
          # which LXC translates to LXC::Error. So we try to call the script
          # multiple times, until *something* releases the file.
          10.times do
            begin
              LXC.run_command([opts[:script]] + opts[:args])
              break
            rescue LXC::Error
              sleep(0.1)
            end
          end
        end

        _, status = Process.wait2(pid)
        ok(status.exitstatus)
      end

      def runscript_run_network(opts)
        with_configured_network(
          init_script: opts[:init_script],
          net_config: opts[:net_config],
        ) { runscript_running(opts) }
      end
    end
  end
end
