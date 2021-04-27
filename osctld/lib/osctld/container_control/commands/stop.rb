require 'osctld/container_control/command'
require 'osctld/container_control/frontend'
require 'osctld/container_control/runner'

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
      # @param mode [:stop, :shutdown, :kill]
      # @param opts [Hash] options
      # @option opts [Integer] :timeout how log to wait for clean shutdown
      # @return [true]
      def execute(mode, opts = {})
        if !%i(stop shutdown kill).include?(mode)
          raise ArgumentError, "invalid stop mode '#{mode}'"
        end

        CGroup.thaw_tree(ct.cgroup_path) if mode == :kill

        ret = fork_runner(args: [mode, opts])

        if ret.ok?
          true

        elsif mode == :stop
          CGroup.thaw_tree(ct.cgroup_path)
          ret = fork_runner(args: [:kill, opts])
          ret.ok? || ret

        else
          ret
        end
      end
    end

    class Runner < ContainerControl::Runner
      def execute(mode, opts)
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
        lxc_ct.shutdown(opts[:timeout])
        ok
      rescue LXC::Error
        error('unable to shutdown container')
      end

      def do_kill(opts)
        lxc_ct.stop
        ok
      rescue LXC::Error
        error('unable to kill container')
      end
    end
  end
end
