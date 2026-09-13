require 'osctld/container_control/command'
require 'osctld/container_control/frontend'
require 'osctld/container_control/runner'
require 'osctld/container_control/utils/wall'
require 'libosctl'

module OsCtld
  # Stop/shutdown/kill container
  #
  # Available stop modes:
  #
  # - `:stop` attempts a clean shutdown, falls back to kill
  # - `:shutdown` either shuts down the container cleanly, or fails
  # - `:kill` kills the container immediately
  class ContainerControl::Commands::Stop < ContainerControl::Command
    class Frontend < ContainerControl::Frontend
      include ContainerControl::Utils::Wall::Frontend

      # @param mode [:stop, :shutdown, :kill]
      # @param opts [Hash] options
      # @option opts [Integer] :timeout how log to wait for clean shutdown
      # @option opts [String, nil] :message
      # @return [true]
      def execute(mode, **opts)
        unless %i[stop shutdown kill].include?(mode)
          raise ArgumentError, "invalid stop mode '#{mode}'"
        end

        CGroup.thaw_tree(ct.cgroup_path) if mode == :kill

        if opts[:message] && ct.running?
          opts = opts.merge(message: make_message(opts[:message]))
        else
          opts.delete(:message)
        end

        ret =
          if %i[stop shutdown].include?(mode) && ct.running?
            exec_runner(
              args: [mode, opts.merge(halt_from_inside: true)],
              switch_extra_namespaces: false
            )
          else
            fork_runner(args: [mode, opts])
          end

        if ret.ok?
          # LXC cannot remove a payload still containing the shutdown runner.
          # exec_runner has now reaped it and removed its osctl.attach leaf.
          # Remove the empty payload before the next start chooses a suffixed
          # cgroup and leaves helpers in the old, unsuffixed sibling.
          CGroup.rmpath_all(ct.payload_cgroup_path)
          true

        elsif mode == :stop
          CGroup.thaw_tree(ct.cgroup_path)
          ret = fork_runner(args: [:kill, opts])
          CGroup.rmpath_all(ct.payload_cgroup_path) if ret.ok?
          ret.ok? || ret

        else
          ret
        end
      end
    end

    class Runner < ContainerControl::Runner
      include ContainerControl::Utils::Wall::Runner

      def execute(mode, opts)
        if opts[:message]
          begin
            ct_wall(opts[:message])
          rescue LXC::Error
            # ignore
          end
        end

        send(:"do_#{mode}", opts)
      end

      protected

      def do_stop(opts)
        if do_shutdown(opts)[:status]
          ok
        else
          error('kill required')
        end
      end

      def do_shutdown(opts)
        timeout = opts[:timeout]

        if opts[:halt_from_inside]
          halt_seconds = run_halt(timeout)
          timeout -= halt_seconds
          timeout = 60 if timeout < 60
        end

        lxc_ct.shutdown(timeout)
        ok
      rescue LXC::Error
        error('unable to shutdown container')
      end

      def do_kill(_opts)
        lxc_ct.stop
        ok
      rescue LXC::Error
        error('unable to kill container')
      end

      # @return [Integer] halt duration in seconds
      def run_halt(timeout)
        t1 = Time.now

        lxc_attach_wait(timeout:) do
          setup_exec_env

          %w[halt poweroff shutdown].each do |cmd|
            LXC.run_command(cmd)
          rescue LXC::Error
            next
          end
        end

        Time.now - t1
      end
    end
  end
end
